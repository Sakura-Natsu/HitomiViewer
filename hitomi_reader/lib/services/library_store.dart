import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../utils/files.dart';

/// 收藏、历史中保存的画廊摘要，不依赖网络即可展示。
class GallerySummary {
  const GallerySummary({
    required this.id,
    required this.title,
    required this.type,
    required this.pageCount,
    this.language,
    this.artists = const [],
    this.coverHash,
    this.date,
    this.japaneseTitle,
    this.tags,
  });

  factory GallerySummary.fromGallery(Gallery gallery) => GallerySummary(
    id: gallery.id,
    title: gallery.title,
    type: gallery.type,
    pageCount: gallery.files.length,
    language: gallery.language?.name,
    artists: [for (final tag in gallery.artists) tag.name],
    coverHash: gallery.cover?.hash,
    date: gallery.addedDate,
    japaneseTitle: gallery.japaneseTitle,
    tags: [for (final tag in gallery.allTags) tagKey(tag)],
  );

  factory GallerySummary.fromJson(Map<String, dynamic> json) => GallerySummary(
    id: json['id'] as int,
    title: json['title'] as String? ?? '',
    type: json['type'] as String? ?? '',
    pageCount: json['pageCount'] as int? ?? 0,
    language: json['language'] as String?,
    artists: (json['artists'] as List?)?.cast<String>() ?? const [],
    coverHash: json['coverHash'] as String?,
    date: json['date'] == null
        ? null
        : DateTime.tryParse(json['date'] as String),
    japaneseTitle: json['japaneseTitle'] as String?,
    tags: (json['tags'] as List?)?.cast<String>(),
  );

  /// 标签在 [tags] 中的写法：`type:name`，名称保留空格。
  static String tagKey(Tag tag) => '${tag.type.name}:${tag.name}';

  final int id;
  final String title;
  final String type;
  final int pageCount;
  final String? language;
  final List<String> artists;
  final String? coverHash;
  final DateTime? date;
  final String? japaneseTitle;

  /// 全部标签（含作者、社团、原作、角色、类型、语言），见 [tagKey]。
  /// 旧版本保存的记录没有这项，为 null，需要补全后才能按标签筛选。
  final List<String>? tags;

  /// 本地筛选（收藏）：包含的标签都有、排除的标签都没有，
  /// 标题词都出现在标题、日文标题或作者名中（也可以直接输入画廊 ID）。
  bool matches(SearchQuery query) {
    if (query.isEmpty) return true;
    final own = {
      ...?tags,
      if (type.isNotEmpty) 'type:$type',
      if (language != null) 'language:$language',
      for (final artist in artists) 'artist:$artist',
    };
    for (final tag in query.tags) {
      if (own.contains(tagKey(tag)) == tag.isNegative) return false;
    }
    final words = [for (final word in query.titleWords) word.toLowerCase()];
    if (words.isEmpty) return true;
    if (words.length == 1 && (words.first == '$id' || words.first == '#$id')) {
      return true;
    }
    final text = [title, ?japaneseTitle, ...artists].join(' / ').toLowerCase();
    return words.every(text.contains);
  }

  /// 封面（首张图片总有大缩略图）。
  GalleryImage? get cover => coverHash == null
      ? null
      : GalleryImage(
          hash: coverHash!,
          name: '',
          width: 0,
          height: 0,
          hasThumbnail: true,
        );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'type': type,
    'pageCount': pageCount,
    'language': language,
    'artists': artists,
    'coverHash': coverHash,
    'date': date?.toIso8601String(),
    'japaneseTitle': japaneseTitle,
    'tags': tags,
  };
}

class FavoriteEntry {
  const FavoriteEntry(this.gallery, this.addedAt);

  final GallerySummary gallery;
  final DateTime addedAt;
}

class HistoryEntry {
  const HistoryEntry(this.gallery, this.page, this.readAt);

  final GallerySummary gallery;

  /// 上次阅读到的页码（从 0 开始）。
  final int page;
  final DateTime readAt;
}

/// 收藏与阅读历史，保存在应用数据目录的 library.json 中。
class LibraryStore extends ChangeNotifier {
  LibraryStore._(this._file);

  static const int maxHistory = 1000;

  final File _file;
  final Map<int, FavoriteEntry> _favorites = {};
  final Map<int, HistoryEntry> _history = {};
  Timer? _saveTimer;
  Future<void> _saving = Future.value();

  static Future<LibraryStore> open(Directory directory) async {
    final store = LibraryStore._(File('${directory.path}/library.json'));
    await store._load();
    return store;
  }

  Future<void> _load() async {
    if (!await _file.exists()) return;
    var damaged = false;
    try {
      final json =
          jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      // 逐条解析：单条损坏只跳过该条，不影响其余记录。
      for (final item in (json['favorites'] as List? ?? const [])) {
        try {
          final map = item as Map<String, dynamic>;
          final summary = GallerySummary.fromJson(
            map['gallery'] as Map<String, dynamic>,
          );
          _favorites[summary.id] = FavoriteEntry(
            summary,
            DateTime.parse(map['addedAt'] as String),
          );
        } catch (error) {
          damaged = true;
          debugPrint('跳过无法解析的收藏: $error');
        }
      }
      for (final item in (json['history'] as List? ?? const [])) {
        try {
          final map = item as Map<String, dynamic>;
          final summary = GallerySummary.fromJson(
            map['gallery'] as Map<String, dynamic>,
          );
          _history[summary.id] = HistoryEntry(
            summary,
            map['page'] as int? ?? 0,
            DateTime.parse(map['readAt'] as String),
          );
        } catch (error) {
          damaged = true;
          debugPrint('跳过无法解析的历史记录: $error');
        }
      }
    } catch (error) {
      damaged = true;
      debugPrint('读取 library.json 失败: $error');
    }
    // 下次保存会覆盖原文件，先备份以免永久丢失数据。
    if (damaged) await backupFile(_file);
  }

  /// 最近收藏的在前。
  List<FavoriteEntry> get favorites =>
      _favorites.values.toList()
        ..sort((a, b) => b.addedAt.compareTo(a.addedAt));

  /// 最近阅读的在前。
  List<HistoryEntry> get history =>
      _history.values.toList()..sort((a, b) => b.readAt.compareTo(a.readAt));

  bool isFavorite(int id) => _favorites.containsKey(id);

  /// 还没有标签信息的收藏（旧版本保存的记录）。
  int get favoritesMissingTags => _favorites.values
      .where(
        (entry) =>
            entry.gallery.tags == null &&
            !_unavailable.contains(entry.gallery.id),
      )
      .length;

  bool _filling = false;

  /// 正在补全收藏的标签信息。
  bool get isFillingDetails => _filling;

  /// 本次运行中获取失败的画廊（可能已从网站删除），不再重复请求。
  final Set<int> _unavailable = {};

  /// 为没有标签信息的收藏补全详情：每本请求一次画廊信息，完成一本更新一本。
  Future<void> fillFavoriteDetails(
    Future<Gallery> Function(int id) fetch, {
    int concurrency = 4,
  }) async {
    if (_filling) return;
    final ids = [
      for (final entry in _favorites.values)
        if (entry.gallery.tags == null &&
            !_unavailable.contains(entry.gallery.id))
          entry.gallery.id,
    ];
    if (ids.isEmpty) return;
    _filling = true;
    _changed();
    var next = 0;
    Future<void> worker() async {
      while (next < ids.length) {
        final id = ids[next++];
        try {
          final summary = GallerySummary.fromGallery(await fetch(id));
          final favorite = _favorites[id];
          if (favorite != null) {
            _favorites[id] = FavoriteEntry(summary, favorite.addedAt);
          }
          final history = _history[id];
          if (history != null && history.gallery.tags == null) {
            _history[id] = HistoryEntry(summary, history.page, history.readAt);
          }
          _changed();
        } catch (error) {
          _unavailable.add(id);
          debugPrint('补全收藏 #$id 的信息失败: $error');
        }
      }
    }

    try {
      await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
    } finally {
      _filling = false;
      _changed();
    }
  }

  HistoryEntry? historyOf(int id) => _history[id];

  void setFavorite(Gallery gallery, bool favorite) {
    if (favorite) {
      _favorites[gallery.id] = FavoriteEntry(
        GallerySummary.fromGallery(gallery),
        DateTime.now(),
      );
    } else {
      _favorites.remove(gallery.id);
    }
    _changed();
  }

  void removeFavorite(int id) {
    if (_favorites.remove(id) != null) _changed();
  }

  void recordRead(Gallery gallery, int page) {
    _history[gallery.id] = HistoryEntry(
      GallerySummary.fromGallery(gallery),
      page,
      DateTime.now(),
    );
    if (_history.length > maxHistory) {
      final oldest = history.skip(maxHistory).map((e) => e.gallery.id).toList();
      oldest.forEach(_history.remove);
    }
    _changed();
  }

  void removeHistory(int id) {
    if (_history.remove(id) != null) _changed();
  }

  void clearHistory() {
    _history.clear();
    _changed();
  }

  void _changed() {
    // 阅读页会在 initState / dispose 中记录进度，此时不能同步通知监听者。
    final scheduler = SchedulerBinding.instance;
    final phase = scheduler.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      notifyListeners();
    } else {
      scheduler.addPostFrameCallback((_) => notifyListeners());
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), save);
  }

  /// 立即保存。多次调用会按顺序执行。
  Future<void> save() {
    _saveTimer?.cancel();
    return _saving = _saving
        .then((_) => _write())
        .catchError((Object error) => debugPrint('保存 library.json 失败: $error'));
  }

  /// 先写入临时文件再重命名，避免写入中断导致文件损坏。
  Future<void> _write() async {
    final json = jsonEncode({
      'favorites': [
        for (final entry in _favorites.values)
          {
            'gallery': entry.gallery.toJson(),
            'addedAt': entry.addedAt.toIso8601String(),
          },
      ],
      'history': [
        for (final entry in _history.values)
          {
            'gallery': entry.gallery.toJson(),
            'page': entry.page,
            'readAt': entry.readAt.toIso8601String(),
          },
      ],
    });
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(json, flush: true);
    await temp.rename(_file.path);
  }
}
