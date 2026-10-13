import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'constants.dart';
import 'error.dart';
import 'hitomi.dart';
import 'index_provider.dart';
import 'models/gallery.dart';
import 'models/tag.dart';

enum SortType {
  dateAdded('added'),
  datePublished('published'),
  random('random'),
  popularityDay('today'),
  popularityWeek('week'),
  popularityMonth('month'),
  popularityYear('year');

  const SortType(this.value);

  final String value;

  bool get isPopularity => switch (this) {
    popularityDay ||
    popularityWeek ||
    popularityMonth ||
    popularityYear => true,
    _ => false,
  };
}

class GalleryListResult {
  const GalleryListResult(this.ids, {this.ignoredWords = const []});

  final List<int> ids;

  /// 宽松匹配时，因索引中不存在而被忽略的标题词。
  final List<String> ignoredWords;
}

class GalleryIdPage {
  const GalleryIdPage(this.ids, this.total);

  final List<int> ids;

  /// 结果总数，服务器未返回时为 null。
  final int? total;
}

/// 画廊的检索与搜索。
class GalleryManager {
  GalleryManager(this._hitomi, Duration indexMaxAge)
    : index = IndexProvider(_hitomi, 'galleries', indexMaxAge);

  final Hitomi _hitomi;

  /// 标题搜索使用的 galleriesindex。
  final IndexProvider index;

  /// 获取 `galleries/{id}.js` 中的原始 JSON。
  Future<Map<String, dynamic>> retrieveJson(int id) async {
    final text = (await _hitomi.request(
      resourceDomain,
      '/galleries/$id.js',
    )).text;
    final start = text.indexOf('{');
    if (start == -1) {
      throw HitomiException(
        HitomiErrorCode.unexpectedResponseBody,
        'Gallery $id response does not contain JSON',
      );
    }
    return jsonDecode(text.substring(start)) as Map<String, dynamic>;
  }

  Future<Gallery> retrieve(int id) async =>
      Gallery.fromJson(await retrieveJson(id));

  /// 生成 nozomi 文件路径，对应 search.js 的 nozomi_address_from_state。
  static String nozomiPath({
    Tag? tag,
    String? language,
    SortType orderBy = SortType.dateAdded,
  }) {
    var order = switch (orderBy) {
      SortType.datePublished => 'date/published',
      SortType.dateAdded || SortType.random => '',
      _ => 'popular/${orderBy.value}',
    };

    if (tag == null || tag.type == TagType.language) {
      final lang = Uri.encodeComponent(tag?.name ?? language ?? 'all');
      return '/n/${order.isEmpty ? 'index' : order}-$lang.nozomi';
    }

    if (order.isNotEmpty) order += '/';

    final String area;
    if (tag.type == TagType.male || tag.type == TagType.female) {
      area = 'tag/';
      order += '${tag.type.name}:';
    } else {
      area = '${tag.type.name}/';
    }

    final lang = Uri.encodeComponent(language ?? 'all');
    return '/n/$area$order${Uri.encodeComponent(tag.name)}-$lang.nozomi';
  }

  static List<int> _decodeIds(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    return [for (var i = 0; i + 4 <= bytes.length; i += 4) view.getInt32(i)];
  }

  /// 完整 nozomi 文件的短期缓存（如语言索引，中文约 0.8 MB），反复调整筛选条件时不必重复下载。
  final Map<String, (DateTime, Future<Uint8List?>)> _nozomiFiles = {};
  static const int _maxCachedNozomiFiles = 8;
  static const Duration _nozomiMaxAge = Duration(minutes: 10);

  /// 读取 nozomi 文件中的画廊 ID。文件不存在时返回空列表（与网站行为一致）。
  Future<List<int>> _requestIds(String path, {String? range}) async {
    if (range == null) {
      final bytes = await _nozomiFile(path);
      return bytes == null ? const [] : _decodeIds(bytes);
    }
    final response = await _hitomi.request(
      resourceDomain,
      path,
      range: range,
      allowStatus: const {404},
    );
    if (response.statusCode == 404) return const [];
    return _decodeIds(response.bytes);
  }

  Future<Uint8List?> _nozomiFile(String path) {
    final cached = _nozomiFiles.remove(path);
    if (cached != null &&
        DateTime.now().difference(cached.$1) < _nozomiMaxAge) {
      _nozomiFiles[path] = cached;
      return cached.$2;
    }
    final future = _hitomi
        .request(resourceDomain, path, allowStatus: const {404})
        .then((response) => response.statusCode == 404 ? null : response.bytes);
    if (_nozomiFiles.length >= _maxCachedNozomiFiles) {
      _nozomiFiles.remove(_nozomiFiles.keys.first);
    }
    _nozomiFiles[path] = (DateTime.now(), future);
    future.catchError((Object _) {
      _nozomiFiles.remove(path);
      return null;
    });
    return future;
  }

  /// 标签组合能否使用 Range 请求直接分页：
  /// 至多一个非语言标签 + 一个语言标签，不能有排除标签、标题关键词或随机排序。
  static bool isPageable({
    List<Tag> tags = const [],
    String? title,
    SortType orderBy = SortType.dateAdded,
  }) {
    if (orderBy == SortType.random) return false;
    if (title != null && title.trim().isNotEmpty) return false;
    if (tags.any((tag) => tag.isNegative)) return false;
    final languages = tags.where((tag) => tag.type == TagType.language).length;
    return languages <= 1 && tags.length - languages <= 1;
  }

  /// 使用 Range 请求获取一页结果，并通过 Content-Range 得到总数。
  Future<GalleryIdPage> listPage({
    List<Tag> tags = const [],
    SortType orderBy = SortType.dateAdded,
    required int page,
    int pageSize = 25,
  }) async {
    if (!isPageable(tags: tags, orderBy: orderBy)) {
      throw HitomiException(
        HitomiErrorCode.invalidCombination,
        'Paging must be used with at most one non-language tag, '
        'no negative tag and no random order',
      );
    }
    if (page < 0 || pageSize <= 0) {
      throw HitomiException(
        HitomiErrorCode.invalidArgument,
        'Page must be non-negative and page size must be positive',
      );
    }

    String? language;
    Tag? tag;
    for (final item in tags) {
      if (item.type == TagType.language) {
        language = item.name;
      } else {
        tag = item;
      }
    }

    final start = page * pageSize * 4;
    final end = start + pageSize * 4 - 1;
    final response = await _hitomi.request(
      resourceDomain,
      nozomiPath(tag: tag, language: language, orderBy: orderBy),
      range: '$start-$end',
      allowStatus: const {404, 416},
    );

    if (response.statusCode == 404) return const GalleryIdPage([], 0);
    final totalBytes = response.totalLength;
    final total = totalBytes == null ? null : totalBytes ~/ 4;
    if (response.statusCode == 416) return GalleryIdPage(const [], total);

    var bytes = response.bytes;
    // 服务器忽略 Range 时会返回完整文件，此时在本地截取。
    if (response.statusCode == 200 && bytes.length > end - start + 1) {
      bytes = Uint8List.sublistView(
        bytes,
        min(start, bytes.length),
        min(end + 1, bytes.length),
      );
    }
    return GalleryIdPage(_decodeIds(bytes), total);
  }

  /// 预取标题索引的版本与上面几层节点（例如用户打开搜索框时），之后每个词少走几次网络往返。
  Future<void> warmUpTitleIndex({int levels = 2}) async {
    try {
      await index.prefetch(await index.version.get(), levels: levels);
    } on Object {
      // 预热失败不影响之后的正常搜索。
    }
  }

  /// 提前查询标题中的词（例如用户还在输入时），真正搜索时直接命中缓存。
  Future<void> prefetchTitle(String title) async {
    try {
      await _titleSets(_splitWords(title), lenient: true);
    } on Object {
      // 预取失败不影响之后的正常搜索。
    }
  }

  static List<String> _splitWords(String? title) => (title ?? '')
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toSet()
      .toList();

  /// 词 → 索引数据位置（null 表示不存在），键为 `索引版本|词`。
  final Map<String, IndexData?> _termData = {};
  static const int _maxCachedTerms = 4096;

  /// 词 → 画廊 ID，只缓存结果不多的词，键为 `索引版本|词`。
  final Map<String, Set<int>> _termIds = {};
  static const int _maxCachedTermIds = 256;
  static const int _maxCachedTermIdCount = 50000;

  /// 数据超过这个大小（约 26 万个画廊）的词视为常见词，如日语助词 no、ga、wa。
  static const int _commonTermBytes = 1 << 20;

  /// 宽松模式下，其他词的交集不超过这个数量时跳过常见词，不再下载它们的大列表。
  static const int _narrowEnough = 5000;

  static void _remember<V>(Map<String, V> cache, String key, V value, int max) {
    cache.remove(key);
    if (cache.length >= max) cache.remove(cache.keys.first);
    cache[key] = value;
  }

  /// 批量查找词在索引中的位置（同一层的节点合并请求），结果带缓存。
  Future<Map<String, IndexData?>> _lookupTerms(
    Iterable<String> terms,
    String version,
  ) async {
    final result = <String, IndexData?>{};
    final missing = <String>[];
    for (final term in terms) {
      final key = '$version|$term';
      if (_termData.containsKey(key)) {
        result[term] = _termData[key];
      } else {
        missing.add(term);
      }
    }
    if (missing.isNotEmpty) {
      final found = await index.searchMany([
        for (final term in missing) _hitomi.hashTerm(term),
      ], version);
      for (var i = 0; i < missing.length; i++) {
        result[missing[i]] = found[i];
        _remember(
          _termData,
          '$version|${missing[i]}',
          found[i],
          _maxCachedTerms,
        );
      }
    }
    return result;
  }

  /// 下载多个词的画廊 ID，合并为一次 multi-range 请求，结果带缓存。
  Future<Map<String, Set<int>>> _fetchTermIds(
    Map<String, IndexData> terms,
    String version,
  ) async {
    final result = <String, Set<int>>{};
    final ranges = <(int, int)>[];
    final termsAt = <int, List<String>>{};
    for (final MapEntry(key: term, value: data) in terms.entries) {
      final cached = _termIds['$version|$term'];
      if (cached != null) {
        result[term] = cached;
      } else if (data.length <= 4) {
        result[term] = <int>{};
      } else {
        final start = data.offset + 4;
        final list = termsAt[start] ??= [];
        if (list.isEmpty) ranges.add((start, data.offset + data.length - 1));
        list.add(term);
      }
    }

    await Future.wait([
      for (var i = 0; i < ranges.length; i += 200)
        _hitomi
            .requestRanges(
              resourceDomain,
              index.dataPath(version),
              ranges.sublist(
                i,
                i + 200 > ranges.length ? ranges.length : i + 200,
              ),
            )
            .then((parts) {
              for (final MapEntry(key: start, value: names)
                  in termsAt.entries) {
                final bytes = parts[start];
                if (bytes == null) continue;
                final ids = _decodeIds(bytes).toSet();
                for (final term in names) {
                  result[term] = ids;
                  if (ids.length <= _maxCachedTermIdCount) {
                    _remember(
                      _termIds,
                      '$version|$term',
                      ids,
                      _maxCachedTermIds,
                    );
                  }
                }
              }
            }),
    ]);

    for (final names in termsAt.values) {
      for (final term in names) {
        if (!result.containsKey(term)) {
          throw HitomiException(
            HitomiErrorCode.unexpectedResponseBody,
            'Missing data range for title word "$term"',
          );
        }
      }
    }
    return result;
  }

  /// 词首尾的标点，如 `fuyashimasu!!`、`(c105)`。
  static final RegExp _edgePunctuation = RegExp(
    r'^[\p{P}\p{S}]+|[\p{P}\p{S}]+$',
    unicode: true,
  );

  /// 词中间的分隔符（保留连字符和撇号），如中文标题里的 `～`、`，`。
  static final RegExp _innerSeparators = RegExp(
    r"[^\p{L}\p{N}\p{M}\-'’]+",
    unicode: true,
  );

  /// 查找标题词对应的画廊集合（多个集合需同时满足）以及被忽略的词。
  ///
  /// 宽松模式下，找不到的词依次尝试去掉首尾标点、按中间的标点拆分，仍找不到则忽略；
  /// 所有候选形式一次性批量查找。另外在其他词已足够缩小范围时，跳过结果过多的常见词。
  Future<(List<Set<int>>, List<String>)> _titleSets(
    List<String> words, {
    required bool lenient,
  }) async {
    if (words.isEmpty) return (const <Set<int>>[], const <String>[]);
    final version = await index.version.get();

    final plans = [
      for (final word in words)
        if (lenient) _TitleWordPlan.lenient(word) else _TitleWordPlan(word),
    ];
    final data = await _lookupTerms({
      for (final plan in plans) ...plan.terms,
    }, version);

    final chosen = <String>{};
    final ignored = <String>[];
    for (final plan in plans) {
      final (terms, missing) = plan.resolve(data);
      chosen.addAll(terms);
      ignored.addAll(missing);
    }
    if (ignored.isNotEmpty && (!lenient || chosen.isEmpty)) {
      return (const <Set<int>>[], ignored);
    }

    final found = {for (final term in chosen) term: data[term]!};
    final sorted = found.keys.toList()
      ..sort((a, b) => found[a]!.length.compareTo(found[b]!.length));
    final rare = [
      for (final term in sorted)
        if (found[term]!.length <= _commonTermBytes) term,
    ];
    final common = [
      for (final term in sorted)
        if (found[term]!.length > _commonTermBytes) term,
    ];

    final sets = <Set<int>>[];
    if (rare.isNotEmpty) {
      final ids = await _fetchTermIds({
        for (final term in rare) term: found[term]!,
      }, version);
      sets.addAll(rare.map((term) => ids[term]!));
    }
    if (common.isNotEmpty &&
        !(lenient &&
            rare.isNotEmpty &&
            _intersectionSize(sets) <= _narrowEnough)) {
      final ids = await _fetchTermIds({
        for (final term in common) term: found[term]!,
      }, version);
      sets.addAll(common.map((term) => ids[term]!));
    }
    return (sets, ignored);
  }

  static int _intersectionSize(List<Set<int>> sets) {
    if (sets.isEmpty) return 0;
    final smallest = sets.reduce((a, b) => a.length <= b.length ? a : b);
    return smallest.where((id) => sets.every((set) => set.contains(id))).length;
  }

  /// 列出符合条件的全部画廊 ID（标题词需全部存在于索引中，与网站行为一致）。
  ///
  /// 支持任意数量的标签（包括排除标签）与标题关键词，会下载完整的 nozomi 文件再取交集。
  /// 若只需要分页浏览简单查询，[listPage] 要快得多。
  Future<List<int>> list({
    List<Tag> tags = const [],
    String? title,
    SortType orderBy = SortType.dateAdded,
  }) async => (await search(tags: tags, title: title, orderBy: orderBy)).ids;

  /// 与 [list] 相同，但可以宽松匹配标题。
  ///
  /// [lenientTitle] 为 true 时，索引中找不到的词会先去掉标点或按标点拆分再查，
  /// 仍找不到的词会被忽略（记录在 [GalleryListResult.ignoredWords] 中），
  /// 适合直接粘贴完整标题搜索。
  Future<GalleryListResult> search({
    List<Tag> tags = const [],
    String? title,
    SortType orderBy = SortType.dateAdded,
    bool lenientTitle = false,
  }) async {
    String? language;
    final positives = <Tag>[];
    final negatives = <Tag>[];
    for (final tag in tags) {
      if (tag.isNegative) {
        negatives.add(tag);
      } else if (tag.type == TagType.language) {
        language ??= tag.name;
      } else {
        positives.add(tag);
      }
    }

    final words = _splitWords(title);

    final orderedByDate =
        orderBy == SortType.dateAdded || orderBy == SortType.random;
    final needsBase =
        positives.isEmpty &&
        (words.isEmpty || language != null || !orderedByDate);

    Future<List<int>>? baseFuture;
    if (positives.isNotEmpty) {
      baseFuture = _requestIds(
        nozomiPath(tag: positives.first, language: language, orderBy: orderBy),
      );
    } else if (needsBase) {
      baseFuture = _requestIds(
        nozomiPath(language: language, orderBy: orderBy),
      );
    }

    final positiveFutures = [
      for (final tag in positives.skip(1))
        _requestIds(nozomiPath(tag: tag, language: language))
            .then((ids) => ids.toSet()),
    ];
    final titleFuture = _titleSets(words, lenient: lenientTitle);
    final negativeFutures = <Future<Set<int>>>[
      for (final tag in negatives)
        if (tag.type != TagType.language)
          _requestIds(nozomiPath(tag: tag, language: language))
              .then((ids) => ids.toSet())
        else if (language == null)
          _requestIds(nozomiPath(tag: tag)).then((ids) => ids.toSet()),
    ];

    // 统一等待：逐个 await 时，前一个失败会让其余请求的错误变成未处理异常。
    final results = await Future.wait<Object?>([
      baseFuture ?? Future<List<int>?>.value(),
      Future.wait(positiveFutures),
      titleFuture,
      Future.wait(negativeFutures),
    ]);
    final base = results[0] as List<int>?;
    final positiveSets = results[1] as List<Set<int>>;
    final (titleSets, ignoredWords) =
        results[2] as (List<Set<int>>, List<String>);
    final negativeSets = results[3] as List<Set<int>>;

    // 严格模式下任一词不存在即无结果；宽松模式下所有词都不存在时也无结果。
    if (ignoredWords.isNotEmpty && (!lenientTitle || titleSets.isEmpty)) {
      return GalleryListResult(const [], ignoredWords: ignoredWords);
    }

    final includes = <Set<int>>[...positiveSets, ...titleSets];
    List<int> result;
    if (base != null) {
      result = base;
    } else {
      // 只有标题关键词且按添加时间排序：以第一个关键词的结果为基准，按 ID 倒序。
      result = includes.removeAt(0).toList()..sort((a, b) => b.compareTo(a));
    }

    final seen = <int>{};
    result = [
      for (final id in result)
        if (seen.add(id) &&
            includes.every((set) => set.contains(id)) &&
            !negativeSets.any((set) => set.contains(id)))
          id,
    ];

    if (orderBy == SortType.random) result.shuffle();
    return GalleryListResult(result, ignoredWords: ignoredWords);
  }
}

/// 一个标题词的候选查询形式。
class _TitleWordPlan {
  _TitleWordPlan(this.word) : trimmed = null, pieces = const [];

  factory _TitleWordPlan.lenient(String word) {
    final trimmed = word.replaceAll(GalleryManager._edgePunctuation, '');
    final pieces = trimmed
        .split(GalleryManager._innerSeparators)
        .map((piece) => piece.replaceAll(GalleryManager._edgePunctuation, ''))
        .where((piece) => piece.isNotEmpty)
        .toSet()
        .toList();
    return _TitleWordPlan._(
      word,
      trimmed.isNotEmpty && trimmed != word ? trimmed : null,
      pieces.length > 1 ? pieces : const [],
    );
  }

  _TitleWordPlan._(this.word, this.trimmed, this.pieces);

  final String word;
  final String? trimmed;
  final List<String> pieces;

  Iterable<String> get terms => [word, ?trimmed, ...pieces];

  /// 选出要使用的词，以及找不到的部分。
  (List<String>, List<String>) resolve(Map<String, IndexData?> data) {
    if (data[word] != null) return ([word], const []);
    final trimmed = this.trimmed;
    if (trimmed != null && data[trimmed] != null) return ([trimmed], const []);
    if (pieces.isEmpty) return (const [], [word]);
    return (
      [
        for (final piece in pieces)
          if (data[piece] != null) piece,
      ],
      [
        for (final piece in pieces)
          if (data[piece] == null) piece,
      ],
    );
  }
}
