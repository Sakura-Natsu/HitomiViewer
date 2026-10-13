import 'media.dart';
import 'tag.dart';

/// 画廊类型（`type` 字段）。
const List<String> galleryTypes = [
  'doujinshi',
  'manga',
  'artistcg',
  'gamecg',
  'imageset',
  'anime',
];

/// 另一种语言版本的同一作品。
class TranslatedGallery {
  const TranslatedGallery({
    required this.id,
    required this.language,
    required this.url,
  });

  final int id;
  final Language language;
  final String url;
}

/// 完整的画廊信息，对应 `galleries/{id}.js`。
class Gallery {
  Gallery({
    required this.id,
    required this.title,
    required this.type,
    required this.url,
    required this.language,
    required this.artists,
    required this.groups,
    required this.series,
    required this.characters,
    required this.tags,
    required this.files,
    required this.translations,
    required this.relatedIds,
    required this.isBlocked,
    required this.addedDate,
    this.japaneseTitle,
    this.publishedDate,
    this.video,
    Map<String, dynamic>? raw,
  }) : raw = raw ?? const {};

  factory Gallery.fromJson(Map<String, dynamic> json) {
    List<Tag> dedicated(String key, String field, TagType type) {
      final list = json[key];
      if (list is! List) return const [];
      return [
        for (final item in list)
          if (item is Map && item[field] is String)
            Tag(type, item[field] as String),
      ];
    }

    final tags = <Tag>[];
    final rawTags = json['tags'];
    if (rawTags is List) {
      for (final item in rawTags) {
        if (item is! Map || item['tag'] is! String) continue;
        final type = _truthy(item['male'])
            ? TagType.male
            : _truthy(item['female'])
            ? TagType.female
            : TagType.tag;
        tags.add(Tag(type, item['tag'] as String));
      }
    }

    final rawFiles = json['files'] is List ? json['files'] as List : const [];
    final thumbnailIndex = rawFiles.length ~/ 2;
    final files = <GalleryImage>[];
    for (var i = 0; i < rawFiles.length; i++) {
      final file = rawFiles[i] as Map;
      files.add(
        GalleryImage(
          hash: file['hash'] as String,
          name: (file['name'] ?? '') as String,
          width: _toInt(file['width']) ?? 0,
          height: _toInt(file['height']) ?? 0,
          hasAvif: _truthy(file['hasavif']),
          hasWebp: file.containsKey('haswebp')
              ? _truthy(file['haswebp'])
              : true,
          hasJxl: _truthy(file['hasjxl']),
          hasThumbnail: i == 0 || i == thumbnailIndex,
        ),
      );
    }

    final translations = <TranslatedGallery>[];
    final rawLanguages = json['languages'];
    if (rawLanguages is List) {
      for (final item in rawLanguages) {
        if (item is! Map) continue;
        final id = _toInt(item['galleryid']);
        final name = item['name'];
        if (id == null || name is! String) continue;
        translations.add(
          TranslatedGallery(
            id: id,
            language: Language(
              name,
              (item['language_localname'] as String?) ?? name,
            ),
            url: (item['url'] as String?) ?? '',
          ),
        );
      }
    }

    final languageName = json['language'];
    final videoFileName = json['videofilename'];
    // 视频画廊总是带有缩略图与海报，海报使用第二个文件的哈希。
    final posterFile = files.length > 1 ? files[1] : files.firstOrNull;

    return Gallery(
      id: _toInt(json['id']) ?? 0,
      title: (json['title'] as String?) ?? '',
      japaneseTitle: json['japanese_title'] as String?,
      type: (json['type'] as String?) ?? '',
      url: (json['galleryurl'] as String?) ?? '',
      language: languageName is String && languageName.isNotEmpty
          ? Language(
              languageName,
              (json['language_localname'] as String?) ?? languageName,
            )
          : null,
      artists: dedicated('artists', 'artist', TagType.artist),
      groups: dedicated('groups', 'group', TagType.group),
      series: dedicated('parodys', 'parody', TagType.series),
      characters: dedicated('characters', 'character', TagType.character),
      tags: tags,
      files: files,
      translations: translations,
      relatedIds: [
        if (json['related'] is List)
          for (final id in json['related'] as List)
            if (_toInt(id) case final int value) value,
      ],
      isBlocked: _truthy(json['blocked']),
      addedDate: parseHitomiDate(json['date'] as String?) ?? DateTime(1970),
      publishedDate: parseHitomiDate(json['datepublished'] as String?),
      video:
          videoFileName is String &&
              videoFileName.isNotEmpty &&
              posterFile != null
          ? Video(
              fileName: videoFileName,
              posterHash: posterFile.hash,
              width: posterFile.width,
              height: posterFile.height,
            )
          : null,
      raw: json,
    );
  }

  final int id;
  final String title;

  /// 已弃用字段，目前总为 null。
  final String? japaneseTitle;

  /// 见 [galleryTypes]。
  final String type;

  /// 网站上的相对路径，如 `/doujinshi/xxx-123.html`。
  final String url;
  final Language? language;
  final List<Tag> artists;
  final List<Tag> groups;
  final List<Tag> series;
  final List<Tag> characters;

  /// 普通标签以及 male / female 标签。
  final List<Tag> tags;
  final List<GalleryImage> files;
  final List<TranslatedGallery> translations;
  final List<int> relatedIds;
  final bool isBlocked;
  final DateTime addedDate;
  final DateTime? publishedDate;
  final Video? video;

  /// 原始 JSON，可用于离线保存后再次通过 [Gallery.fromJson] 还原。
  final Map<String, dynamic> raw;

  Map<String, dynamic> toJson() => raw;

  String get webUrl => 'https://hitomi.la$url';

  /// 首张图片与中间图片，这两张有大尺寸缩略图。
  List<GalleryImage> get thumbnails =>
      files.isEmpty ? const [] : [files.first, files[files.length ~/ 2]];

  GalleryImage? get cover => files.firstOrNull;

  /// 所有标签（包括作者、社团、系列、角色、类型和语言）。
  List<Tag> get allTags => [
    if (type.isNotEmpty) Tag(TagType.type, type),
    if (language != null) language!.toTag(),
    ...artists,
    ...groups,
    ...series,
    ...characters,
    ...tags,
  ];
}

/// 解析形如 `2026-10-13 04:23:00-05` 的日期。
DateTime? parseHitomiDate(String? value) {
  if (value == null || value.isEmpty) return null;
  return DateTime.tryParse(value) ??
      DateTime.tryParse(value.replaceFirst(' ', 'T'));
}

bool _truthy(Object? value) => switch (value) {
  null => false,
  bool b => b,
  num n => n != 0,
  String s => s.isNotEmpty && s != '0',
  _ => true,
};

int? _toInt(Object? value) => switch (value) {
  int i => i,
  num n => n.toInt(),
  String s => int.tryParse(s),
  _ => null,
};
