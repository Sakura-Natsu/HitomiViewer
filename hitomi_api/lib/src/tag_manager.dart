import 'constants.dart';
import 'error.dart';
import 'hitomi.dart';
import 'models/gallery.dart';
import 'models/tag.dart';

class TagSuggestion {
  const TagSuggestion(this.tag, this.count);

  final Tag tag;

  /// 带有该标签的画廊数量。
  final int count;
}

/// 解析后的搜索语句：标签 + 标题关键词。
class SearchQuery {
  const SearchQuery({this.tags = const [], String? title})
    : title = title == null || title == '' ? null : title;

  final List<Tag> tags;

  /// 标题关键词（保留原文），null 表示不按标题筛选。
  final String? title;

  List<String> get titleWords => title == null
      ? const []
      : title!.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  bool get isEmpty => tags.isEmpty && titleWords.isEmpty;

  SearchQuery copyWith({List<Tag>? tags, String? title}) =>
      SearchQuery(tags: tags ?? this.tags, title: title ?? this.title);

  SearchQuery withoutTitle() => SearchQuery(tags: tags);

  /// 可被 [TagManager.parseQuery] 还原的字符串形式。
  @override
  String toString() => [
    ...tags.map((tag) => '$tag'),
    if (title != null) title!.trim(),
  ].join(' ');
}

/// 列出标签时可用的首字母，`123` 表示非字母开头。
const List<String> nameInitials = [
  'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', //
  'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', '123',
];

String _replaceSmartQuotes(String value) => value.replaceAllMapped(
  RegExp('[“”‘’–—]'),
  (match) => switch (match[0]) {
    '“' || '”' => '"',
    '‘' || '’' => "'",
    _ => '-',
  },
);

class TagManager {
  TagManager(this._hitomi);

  final Hitomi _hitomi;

  /// 创建标签，名称中的下划线会被替换为空格。
  Tag create(TagType type, String name, {bool isNegative = false}) {
    if (name.isEmpty) {
      throw HitomiException(
        HitomiErrorCode.invalidArgument,
        'Name must not be empty',
      );
    }
    return Tag(type, name.replaceAll('_', ' '), isNegative: isNegative);
  }

  /// 解析以空格分隔的 `[-]type:name` 表达式，忽略重复项、无冒号的词与未知类型。
  List<Tag> parse(String expression) => parseQuery(expression).tags;

  /// 解析搜索框输入：`[-]type:name` 视为标签，其余词原样作为标题关键词。
  ///
  /// 类型无法识别的词（如标题中的 `Re:Zero`）也视为标题关键词。
  SearchQuery parseQuery(String input) {
    final tags = <Tag>[];
    final seenTags = <Tag>{};
    final words = <String>[];

    for (final token in _replaceSmartQuotes(
      input,
    ).trim().split(RegExp(r'\s+'))) {
      if (token.isEmpty || token == '-') continue;
      final tag = _parseTag(token);
      if (tag == null) {
        words.add(token);
      } else if (seenTags.add(tag)) {
        tags.add(tag);
      }
    }

    return SearchQuery(tags: tags, title: words.join(' '));
  }

  Tag? _parseTag(String token) {
    final colon = token.indexOf(':');
    if (colon == -1) return null;
    final isNegative = token.startsWith('-');
    final type = TagType.tryParse(
      token.substring(isNegative ? 1 : 0, colon).toLowerCase(),
    );
    final name = token.substring(colon + 1).replaceAll('_', ' ').toLowerCase();
    if (type == null || name.isEmpty) return null;
    return Tag(type, name, isNegative: isNegative);
  }

  /// 标签联想。[term] 可带类型前缀，如 `female:big`。
  Future<List<TagSuggestion>> search(String term) async {
    term = _replaceSmartQuotes(term).trim().toLowerCase();
    if (term.startsWith('-')) term = term.substring(1);

    final colon = term.indexOf(':');
    final String field;
    if (colon != -1) {
      final type = TagType.tryParse(term.substring(0, colon));
      if (type == null) {
        throw HitomiException(
          HitomiErrorCode.invalidArgument,
          'Type must be one of ${TagType.values.map((t) => t.name).join(', ')}',
        );
      }
      field = type.name;
      term = term.substring(colon + 1);
    } else {
      field = 'global';
    }
    if (term.isEmpty) return const [];

    // 对应 search.js 的 encode_search_query_for_url，每个字符一级路径。
    final path = StringBuffer('/$field');
    for (final rune in term.runes) {
      final char = String.fromCharCode(rune);
      path
        ..write('/')
        ..write(switch (char) {
          ' ' || '_' => '_',
          '/' => 'slash',
          '.' => 'dot',
          _ => Uri.encodeComponent(char),
        });
    }
    path.write('.json');

    final response = await _hitomi.request(
      tagIndexDomain,
      path.toString(),
      allowStatus: const {404},
    );
    if (response.statusCode == 404 || response.bytes.isEmpty) return const [];

    final results = <TagSuggestion>[];
    for (final item in response.json as List) {
      if (item is! List || item.length < 3) continue;
      final type = TagType.tryParse('${item[2]}');
      if (type == null) continue;
      results.add(
        TagSuggestion(
          Tag(type, '${item[0]}'),
          item[1] is int ? item[1] as int : int.tryParse('${item[1]}') ?? 0,
        ),
      );
    }
    return results;
  }

  /// 列出某一类型下以 [initial] 开头的全部标签（抓取 `all{area}-{initial}.html`）。
  ///
  /// `language` 与 `type` 类型不需要 [initial]。
  Future<List<Tag>> list(TagType type, [String? initial]) async {
    switch (type) {
      case TagType.type:
        return [for (final name in galleryTypes) Tag(type, name)];
      case TagType.language:
        return [for (final language in Language.ordered) language.toTag()];
      default:
        break;
    }

    if (initial == null || !nameInitials.contains(initial)) {
      throw HitomiException(
        HitomiErrorCode.invalidArgument,
        'Initial must be one of ${nameInitials.join(', ')}',
      );
    }

    var target = 'href="/${type.name}/';
    final String area;
    switch (type) {
      case TagType.male:
      case TagType.female:
        target = 'href="/tag/${type.name}%3A';
        area = 'tags';
      case TagType.tag:
        area = 'tags';
      case TagType.series:
        area = 'series';
      default:
        area = '${type.name}s';
    }

    final html = (await _hitomi.request(
      frontDomain,
      '/all$area-$initial.html',
    )).text;
    final tags = <Tag>[];
    var index = 0;
    while (true) {
      final start = html.indexOf(target, index);
      if (start == -1) break;
      final nameStart = start + target.length;
      final end = html.indexOf('.html', nameStart);
      if (end == -1) break;
      index = end;

      // 普通标签页中也会出现 male / female 标签的链接，需要跳过。
      if (type == TagType.tag &&
          (html.startsWith('male', nameStart) ||
              html.startsWith('female', nameStart))) {
        continue;
      }

      var encoded = html.substring(nameStart, end);
      if (encoded.endsWith('-all')) {
        encoded = encoded.substring(0, encoded.length - 4);
      }
      tags.add(Tag(type, Uri.decodeComponent(encoded)));
    }
    return tags;
  }

  /// 该标签下的作品有哪些语言（对应 node-hitomi 的 `Tag.listLanguages`）。
  Future<List<Language>> listLanguages(Tag tag) async {
    final String term;
    switch (tag.type) {
      case TagType.male:
      case TagType.female:
        term = 'tag/${tag.type.name}:${tag.name}';
      case TagType.language:
        final language = Language.byName(tag.name);
        if (language == null) {
          throw HitomiException(
            HitomiErrorCode.invalidField,
            'Name must be valid',
          );
        }
        return [language];
      default:
        term = '${tag.type.name}/${tag.name}';
    }

    final result = await _hitomi.languageIndex.search(_hitomi.hashTerm(term));
    if (result == null) {
      throw HitomiException(HitomiErrorCode.invalidField, 'Name must be valid');
    }

    // languages 索引中 offset 字段被用作语言位掩码。
    final mask = result.$1.offset;
    final bits = await _hitomi.languageSupport();
    return [
      for (var i = 0; i < bits.length && i < 63; i++)
        if (mask & (1 << i) != 0 && bits[i] != null) bits[i]!,
    ];
  }
}
