enum TagType {
  artist,
  group,
  type,
  language,
  series,
  character,
  male,
  female,
  tag;

  static TagType? tryParse(String value) {
    for (final type in values) {
      if (type.name == value) return type;
    }
    return null;
  }
}

/// 用于筛选画廊的标签，如 `female:big breasts`。
class Tag {
  const Tag(this.type, this.name, {this.isNegative = false});

  final TagType type;

  /// 标签名，空格保持为空格（而不是下划线）。
  final String name;

  /// 为 true 时表示排除该标签。
  final bool isNegative;

  Tag negate([bool? negative]) =>
      Tag(type, name, isNegative: negative ?? !isNegative);

  /// 网站上浏览该标签的路径。
  String get url {
    switch (type) {
      case TagType.male:
      case TagType.female:
        return '/tag/${type.name}%3A${Uri.encodeComponent(name)}-all.html';
      case TagType.language:
        return '/index-${Uri.encodeComponent(name)}.html';
      default:
        return '/${type.name}/${Uri.encodeComponent(name)}-all.html';
    }
  }

  /// 格式为 `[-]type:name`，名称中的空格替换为下划线，可被 [TagManager.parse] 还原。
  @override
  String toString() =>
      '${isNegative ? '-' : ''}${type.name}:${name.replaceAll(' ', '_')}';

  @override
  bool operator ==(Object other) =>
      other is Tag &&
      other.type == type &&
      other.name == name &&
      other.isNegative == isNegative;

  @override
  int get hashCode => Object.hash(type, name, isNegative);
}

class Language {
  const Language(this.name, this.localName);

  /// 英文小写名称，如 `chinese`。
  final String name;

  /// 本地语言名称，如 `中文`。
  final String localName;

  String get url => '/index-${Uri.encodeComponent(name)}.html';

  Tag toTag({bool isNegative = false}) =>
      Tag(TagType.language, name, isNegative: isNegative);

  /// languages 索引中位掩码对应的语言，第 i 项对应第 i 位。
  ///
  /// 来自网站自动生成的 language_support.js（`bitnumber_language`），
  /// 运行时会优先使用 [Hitomi.languageSupport] 动态获取的版本。
  static const List<Language> ordered = [
    Language('indonesian', 'Bahasa Indonesia'),
    Language('javanese', 'Basa Jawa'),
    Language('catalan', 'Català'),
    Language('cebuano', 'Cebuano'),
    Language('czech', 'Čeština'),
    Language('danish', 'Dansk'),
    Language('german', 'Deutsch'),
    Language('estonian', 'Eesti'),
    Language('english', 'English'),
    Language('spanish', 'Español'),
    Language('esperanto', 'Esperanto'),
    Language('french', 'Français'),
    Language('hindi', 'Hindi'),
    Language('icelandic', 'Íslenska'),
    Language('italian', 'Italiano'),
    Language('khmer', 'ភាសាខ្មែរ'),
    Language('latin', 'Latina'),
    Language('hungarian', 'Magyar'),
    Language('dutch', 'Nederlands'),
    Language('norwegian', 'Norsk'),
    Language('polish', 'Polski'),
    Language('portuguese', 'Português'),
    Language('romanian', 'Română'),
    Language('albanian', 'Shqip'),
    Language('slovak', 'Slovenčina'),
    Language('serbian', 'Srpski'),
    Language('finnish', 'Suomi'),
    Language('swedish', 'Svenska'),
    Language('tagalog', 'Tagalog'),
    Language('textless narrative', 'Textless'),
    Language('vietnamese', 'Tiếng Việt'),
    Language('turkish', 'Türkçe'),
    Language('greek', 'Ελληνικά'),
    Language('bulgarian', 'Български'),
    Language('mongolian', 'Монгол'),
    Language('russian', 'Русский'),
    Language('ukrainian', 'Українська'),
    Language('hebrew', 'עברית'),
    Language('arabic', 'العربية'),
    Language('persian', 'فارسی'),
    Language('thai', 'ไทย'),
    Language('burmese', 'မြန်မာဘာသာ'),
    Language('korean', '한국어'),
    Language('chinese', '中文'),
    Language('japanese', '日本語'),
  ];

  static Language? byName(String name) {
    for (final language in ordered) {
      if (language.name == name) return language;
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is Language && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'Language($name)';
}
