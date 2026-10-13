import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:hitomi_api/hitomi_api.dart';
import 'package:http/http.dart' as http;

/// 一条标签翻译。
class TagInfo {
  TagInfo(this.name, this.intro, {this.aliases = const []})
    : lowerName = name.toLowerCase();

  /// 中文名。
  final String name;

  /// 小写的中文名，搜索时使用（预先计算，避免每次按键都分配字符串）。
  final String lowerName;

  /// 释义，可能为空。
  final String intro;

  /// 搜索时同样匹配的其他中文名，如 chinese 的「中文」。
  final List<String> aliases;
}

/// 本地标签库的一条匹配结果。
class LocalTagMatch {
  const LocalTagMatch(this.tag, this.info, this.score);

  final Tag tag;
  final TagInfo info;

  /// 越小越靠前：0 完全相同，1 前缀，2 单词开头，3 包含。
  final int score;
}

/// 中文标签库，数据来自 EhTagTranslation 项目（CC BY-NC-SA 3.0）。
///
/// E-Hentai 与 hitomi 的标签基本一致，命名空间对应关系：
/// female/male → 同名；parody → series；other、mixed 以及非语言的 language 条目 → tag；
/// character、group、artist → 同名。
class TagTranslations extends ChangeNotifier {
  TagTranslations._(this._directory, this._client);

  static const String sourceName = 'EhTagTranslation';
  static const String sourceUrl =
      'https://github.com/EhTagTranslation/Database';
  static const String licenseName = 'CC BY-NC-SA 3.0';

  /// 下载源，按顺序尝试。jsDelivr 在国内通常比 GitHub 更容易访问。
  static const List<(String, String)> _sources = [
    (
      'https://cdn.jsdelivr.net/gh/EhTagTranslation/DatabaseReleases/db.text.json.gz',
      'https://cdn.jsdelivr.net/gh/EhTagTranslation/DatabaseReleases/sha',
    ),
    (
      'https://github.com/EhTagTranslation/Database/releases/latest/download/db.text.json.gz',
      'https://github.com/EhTagTranslation/Database/releases/latest/download/sha',
    ),
  ];

  /// 常用语言的其他叫法（EH 中 chinese 译作「汉语」，但用户更常输入「中文」）。
  static const Map<String, List<String>> _languageAliases = {
    'chinese': ['中文', '中国语', '华语'],
    'japanese': ['日文', '日本语'],
    'english': ['英文'],
    'korean': ['韩文', '朝鲜语'],
  };

  /// 搜索时 hitomi 标签类型的优先顺序。
  static const List<TagType> _typeOrder = [
    TagType.female,
    TagType.male,
    TagType.tag,
    TagType.language,
    TagType.series,
    TagType.character,
    TagType.group,
    TagType.artist,
  ];

  final Directory _directory;
  final http.Client _client;

  Map<TagType, Map<String, TagInfo>> _data = const {};
  String? _sha;
  DateTime? _updatedAt;
  DateTime? _checkedAt;
  bool _updating = false;
  Object? _lastError;

  File get _databaseFile => File('${_directory.path}/db.text.json.gz');
  File get _metaFile => File('${_directory.path}/meta.json');

  bool get isLoaded => _data.isNotEmpty;
  bool get isUpdating => _updating;
  Object? get lastError => _lastError;
  DateTime? get updatedAt => _updatedAt;
  int get count => _data.values.fold(0, (sum, map) => sum + map.length);

  static Future<TagTranslations> open(
    Directory directory,
    http.Client client,
  ) async {
    final translations = TagTranslations._(directory, client);
    await translations._loadFromDisk();
    return translations;
  }

  Future<void> _loadFromDisk() async {
    try {
      if (await _metaFile.exists()) {
        final meta =
            jsonDecode(await _metaFile.readAsString()) as Map<String, dynamic>;
        _sha = meta['sha'] as String?;
        _updatedAt = DateTime.tryParse(meta['updatedAt'] as String? ?? '');
        _checkedAt = DateTime.tryParse(meta['checkedAt'] as String? ?? '');
      }
      if (await _databaseFile.exists()) {
        final bytes = await _databaseFile.readAsBytes();
        _data = await Isolate.run(() => _parse(bytes));
        notifyListeners();
      }
    } catch (error) {
      debugPrint('读取中文标签库失败: $error');
    }
  }

  /// 距上次检查超过一天时检查更新（失败时静默）。
  Future<void> updateIfStale() async {
    final checkedAt = _checkedAt;
    if (isLoaded &&
        checkedAt != null &&
        DateTime.now().difference(checkedAt) < const Duration(days: 1)) {
      return;
    }
    await update();
  }

  /// 检查并下载最新的标签库。[force] 为 true 时即使版本相同也重新下载。
  Future<bool> update({bool force = false}) async {
    if (_updating) return false;
    _updating = true;
    _lastError = null;
    notifyListeners();
    try {
      Object? error;
      for (final (databaseUrl, shaUrl) in _sources) {
        try {
          final sha = (await _get(shaUrl)).trim();
          if (!force && isLoaded && sha.isNotEmpty && sha == _sha) {
            await _saveMeta(checkedAt: DateTime.now());
            return false;
          }
          final bytes = await _getBytes(databaseUrl);
          final data = await Isolate.run(() => _parse(bytes));
          if (data.isEmpty) throw const FormatException('标签库为空');
          await _directory.create(recursive: true);
          final temp = File('${_databaseFile.path}.tmp');
          await temp.writeAsBytes(bytes, flush: true);
          await temp.rename(_databaseFile.path);
          _data = data;
          _sha = sha.isEmpty ? null : sha;
          _updatedAt = DateTime.now();
          await _saveMeta(checkedAt: DateTime.now());
          return true;
        } catch (e) {
          error = e;
          debugPrint('从 $databaseUrl 更新中文标签库失败: $e');
        }
      }
      _lastError = error;
      return false;
    } finally {
      _updating = false;
      notifyListeners();
    }
  }

  Future<String> _get(String url) async =>
      utf8.decode(await _getBytes(url), allowMalformed: true);

  Future<Uint8List> _getBytes(String url) async {
    final response = await _client
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }
    return response.bodyBytes;
  }

  Future<void> _saveMeta({required DateTime checkedAt}) async {
    _checkedAt = checkedAt;
    await _directory.create(recursive: true);
    await _metaFile.writeAsString(
      jsonEncode({
        'sha': _sha,
        'updatedAt': _updatedAt?.toIso8601String(),
        'checkedAt': checkedAt.toIso8601String(),
      }),
    );
  }

  /// 在后台 isolate 中解析 db.text.json(.gz)，转换为 hitomi 的标签类型。
  static Map<TagType, Map<String, TagInfo>> _parse(Uint8List bytes) {
    final isGzip = bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
    final text = utf8.decode(isGzip ? gzip.decode(bytes) : bytes);
    final json = jsonDecode(text) as Map<String, dynamic>;

    Map<String, TagInfo> namespace(String name) {
      for (final item in json['data'] as List) {
        final map = item as Map<String, dynamic>;
        if (map['namespace'] != name) continue;
        return {
          for (final MapEntry(:key, :value)
              in (map['data'] as Map<String, dynamic>).entries)
            key: TagInfo(
              ((value as Map)['name'] as String? ?? key).trim(),
              (value['intro'] as String? ?? '').trim(),
            ),
        };
      }
      return const {};
    }

    final language = {
      for (final MapEntry(:key, :value) in namespace('language').entries)
        key: _languageAliases.containsKey(key)
            ? TagInfo(value.name, value.intro, aliases: _languageAliases[key]!)
            : value,
    };
    // language 中除真实语言外的条目（如 rough translation）在 hitomi 上是普通标签
    final languageTags = {
      for (final MapEntry(:key, :value) in language.entries)
        if (Language.byName(key) == null) key: value,
    };
    return {
      TagType.female: namespace('female'),
      TagType.male: namespace('male'),
      TagType.tag: {
        ...languageTags,
        ...namespace('mixed'),
        ...namespace('other'),
      },
      TagType.language: language,
      TagType.series: namespace('parody'),
      TagType.character: namespace('character'),
      TagType.group: namespace('group'),
      TagType.artist: namespace('artist'),
    };
  }

  /// 查找标签的翻译。hitomi 的普通标签在 EH 中也可能带性别，找不到时依次尝试。
  TagInfo? lookup(Tag tag) {
    final name = tag.name.toLowerCase();
    final info = _data[tag.type]?[name];
    if (info != null || tag.type != TagType.tag) return info;
    return _data[TagType.female]?[name] ?? _data[TagType.male]?[name];
  }

  static String _normalize(String query) =>
      query.trim().toLowerCase().replaceAll('_', ' ');

  /// 匹配程度：0 完全相同，1 前缀，2 单词开头，3 包含；不匹配返回 -1。
  static int _score(String english, TagInfo info, String query, String spaced) {
    final chinese = info.lowerName;
    final aliases = info.aliases;
    if (english == query ||
        chinese == query ||
        (aliases.isNotEmpty && aliases.contains(query))) {
      return 0;
    }
    if (english.startsWith(query) ||
        chinese.startsWith(query) ||
        (aliases.isNotEmpty && aliases.any((a) => a.startsWith(query)))) {
      return 1;
    }
    if (english.contains(spaced)) return 2;
    if (english.contains(query) ||
        chinese.contains(query) ||
        (aliases.isNotEmpty && aliases.any((a) => a.contains(query)))) {
      return 3;
    }
    return -1;
  }

  static List<LocalTagMatch> _rank(
    List<(int, int, int, LocalTagMatch)> matches,
    int limit,
  ) {
    matches.sort((a, b) {
      if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
      if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
      return a.$3.compareTo(b.$3);
    });
    return [for (final match in matches.take(limit)) match.$4];
  }

  /// 按中文或英文查找标签。[type] 不为空时只在该类型中查找。
  List<LocalTagMatch> search(String query, {TagType? type, int limit = 40}) {
    query = _normalize(query);
    if (query.isEmpty || !isLoaded) return const [];
    final spaced = ' $query';
    final matches = <(int, int, int, LocalTagMatch)>[];
    for (var order = 0; order < _typeOrder.length; order++) {
      final tagType = _typeOrder[order];
      if (type != null && tagType != type) continue;
      for (final MapEntry(key: english, value: info)
          in (_data[tagType] ?? const <String, TagInfo>{}).entries) {
        final score = _score(english, info, query, spaced);
        if (score < 0) continue;
        matches.add((
          score,
          order,
          english.length,
          LocalTagMatch(Tag(tagType, english), info, score),
        ));
      }
    }
    return _rank(matches, limit);
  }

  /// 一次遍历同时完成多个查询以及中文后缀匹配，并且分片执行、定期让出主线程，
  /// 打字时界面不会卡顿。[isCancelled] 返回 true 时提前结束（返回空结果）。
  Future<(List<List<LocalTagMatch>>, List<LocalTagMatch>)> searchBatch(
    List<(TagType?, String)> queries, {
    String? suffixText,
    int limit = 30,
    bool Function()? isCancelled,
  }) async {
    final normalized = [
      for (final (type, query) in queries)
        (type, _normalize(query), ' ${_normalize(query)}'),
    ];
    final buckets = [
      for (var i = 0; i < queries.length; i++)
        <(int, int, int, LocalTagMatch)>[],
    ];
    final suffix = suffixText?.trim().toLowerCase();
    final checkSuffix = suffix != null && suffix.length >= 2;
    final suffixMatches = <LocalTagMatch>[];
    if (!isLoaded) {
      return ([for (final _ in queries) <LocalTagMatch>[]], suffixMatches);
    }

    final data = _data; // 更新时会替换整个 Map，遍历的是旧的那份，不受影响
    var visited = 0;
    for (var order = 0; order < _typeOrder.length; order++) {
      final tagType = _typeOrder[order];
      for (final MapEntry(key: english, value: info)
          in (data[tagType] ?? const <String, TagInfo>{}).entries) {
        for (var i = 0; i < normalized.length; i++) {
          final (type, query, spaced) = normalized[i];
          if (query.isEmpty || (type != null && type != tagType)) continue;
          final score = _score(english, info, query, spaced);
          if (score < 0) continue;
          buckets[i].add((
            score,
            order,
            english.length,
            LocalTagMatch(Tag(tagType, english), info, score),
          ));
        }
        if (checkSuffix) {
          final chinese = info.lowerName;
          if (chinese.length >= 2 &&
              chinese.length < suffix.length &&
              suffix.endsWith(chinese)) {
            suffixMatches.add(LocalTagMatch(Tag(tagType, english), info, 1));
          }
        }
        if (++visited % 4000 == 0) {
          await Future<void>.delayed(Duration.zero);
          if (isCancelled?.call() ?? false) {
            return (const <List<LocalTagMatch>>[], const <LocalTagMatch>[]);
          }
        }
      }
    }
    suffixMatches.sort(
      (a, b) => b.info.name.length.compareTo(a.info.name.length),
    );
    return (
      [for (final bucket in buckets) _rank(bucket, limit)],
      suffixMatches.take(5).toList(),
    );
  }

  /// 文本末尾正好是某个标签的中文名时返回该标签（用于“学园巨乳”这类不带空格的中文输入）。
  List<LocalTagMatch> suffixMatches(String text, {int limit = 5}) {
    text = text.trim().toLowerCase();
    if (text.length < 2 || !isLoaded) return const [];
    final matches = <LocalTagMatch>[];
    for (final tagType in _typeOrder) {
      for (final MapEntry(key: english, value: info)
          in (_data[tagType] ?? const <String, TagInfo>{}).entries) {
        final chinese = info.lowerName;
        if (chinese.length >= 2 &&
            chinese.length < text.length &&
            text.endsWith(chinese)) {
          matches.add(LocalTagMatch(Tag(tagType, english), info, 1));
        }
      }
    }
    matches.sort((a, b) => b.info.name.length.compareTo(a.info.name.length));
    return matches.take(limit).toList();
  }
}
