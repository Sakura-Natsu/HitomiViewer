import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:hitomi_api/hitomi_api.dart';
import 'package:http/http.dart' as http_package;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crop.dart';
import 'download_manager.dart';
import 'gallery_repository.dart';
import 'http_client.dart';
import 'image_loader.dart';
import 'library_store.dart';
import 'settings.dart';
import 'tag_labels.dart';
import 'tag_suggester.dart';
import 'tag_translations.dart';

/// 全局服务。在 [main] 中初始化后通过 [services] 访问。
class AppServices {
  AppServices._({
    required this.settings,
    required this.http,
    required this.hitomi,
    required this.images,
    required this.library,
    required this.downloads,
    required this.galleries,
    required this.translations,
    required this.tagSuggester,
  }) : tagLabels = TagLabels(settings, translations);

  static AppServices? _instance;

  final AppSettings settings;
  final ProxyHttpClient http;
  final Hitomi hitomi;
  final ImageLoader images;
  final LibraryStore library;
  final DownloadManager downloads;
  final GalleryRepository galleries;

  /// 中文标签库。
  final TagTranslations translations;
  final TagSuggester tagSuggester;

  /// 标签显示名称（中文/英文）。
  final TagLabels tagLabels;

  /// 阅读器的白边检测结果。
  final CropCache crops = CropCache();

  static Future<AppServices> init() async {
    await _migrateRenamedDataDirectories();
    final prefs = await SharedPreferences.getInstance();
    final settings = AppSettings(prefs);
    final http = ProxyHttpClient(settings.proxy);
    final support = await getApplicationSupportDirectory();
    final services = await create(
      settings: settings,
      http: http,
      client: http,
      supportDirectory: support,
      cacheDirectory: await getApplicationCacheDirectory(),
      downloadDirectory: await _downloadDirectory(support),
    );

    PaintingBinding.instance.imageCache.maximumSizeBytes = 256 << 20;
    await services.applyProxy();
    // 启动后在后台清理超出上限的图片缓存。
    Timer(const Duration(seconds: 10), () {
      services.images.trimCache(settings.cacheLimitMb << 20).ignore();
    });
    // 中文标签库：首次使用时下载，之后每天检查一次更新。
    if (settings.tagTranslation) {
      Timer(const Duration(seconds: 3), () {
        services.translations.updateIfStale().ignore();
      });
    }
    return services;
  }

  /// 组装各项服务并设为全局实例。测试中可以传入模拟的 [client] 与临时目录。
  @visibleForTesting
  static Future<AppServices> create({
    required AppSettings settings,
    required ProxyHttpClient http,
    required http_package.Client client,
    required Directory supportDirectory,
    required Directory cacheDirectory,
    required Directory downloadDirectory,
  }) async {
    final hitomi = Hitomi(client: client);
    final images = ImageLoader(
      hitomi,
      client,
      Directory('${cacheDirectory.path}/images'),
    );
    final downloads = await DownloadManager.open(downloadDirectory, images);
    final translations = await TagTranslations.open(
      Directory('${supportDirectory.path}/ehtag'),
      client,
    );
    final services = AppServices._(
      settings: settings,
      http: http,
      hitomi: hitomi,
      images: images,
      library: await LibraryStore.open(supportDirectory),
      downloads: downloads,
      galleries: GalleryRepository(hitomi, downloads),
      translations: translations,
      tagSuggester: TagSuggester(
        hitomi,
        translations,
        File('${cacheDirectory.path}/tag_suggest.json'),
      ),
    );
    _instance = services;
    return services;
  }

  /// Windows 上的数据目录按“发布者\产品名”命名（`%APPDATA%\Sakura-Natsu\HitomiViewer`）。
  /// 早期版本的发布者是 com.example、产品名是 Hitomi Reader，首次启动新版本时把旧目录整个
  /// 搬过来，收藏、历史、设置和图片缓存都不会丢。Android 的数据按包名区分，不受影响。
  static Future<void> _migrateRenamedDataDirectories() async {
    if (!Platform.isWindows) return;
    for (final directory in [
      await getApplicationSupportDirectory(),
      await getApplicationCacheDirectory(),
    ]) {
      await migrateDataDirectory(directory, [
        for (final old in [
          'com.example\\HitomiViewer',
          'com.example\\Hitomi Reader',
        ])
          Directory('${directory.parent.parent.path}\\$old'),
      ]);
    }
  }

  /// 新目录为空（或不存在）时，把第一个存在的旧目录整个移动过去。
  @visibleForTesting
  static Future<void> migrateDataDirectory(
    Directory directory,
    List<Directory> candidates,
  ) async {
    try {
      // 新目录里已经有数据（已经迁移过或新版本已经用过），保留新目录
      if (await directory.exists() && !await directory.list().isEmpty) return;
      for (final old in candidates) {
        if (!await old.exists()) continue;
        if (await directory.exists()) await directory.delete();
        await directory.parent.create(recursive: true);
        await old.rename(directory.path);
        debugPrint('已迁移旧数据目录: ${old.path} → ${directory.path}');
        return;
      }
    } on FileSystemException catch (error) {
      debugPrint('迁移旧数据目录失败: $error');
    }
  }

  /// Windows 上下载到“文档/HitomiReader”，便于用户找到；其他平台放在应用目录。
  static Future<Directory> _downloadDirectory(Directory support) async {
    if (Platform.isWindows) {
      final documents = await getApplicationDocumentsDirectory();
      return Directory('${documents.path}/HitomiReader/downloads');
    }
    return Directory('${support.path}/downloads');
  }

  /// 根据设置重建 HTTP 客户端的代理配置。
  Future<void> applyProxy() async {
    final config = settings.proxy;
    final systemProxy = config.mode == ProxyMode.system
        ? await detectWindowsSystemProxy()
        : null;
    http.configure(config, systemProxy: systemProxy);
    hitomi.imageContext().ignore();
  }
}

AppServices get services => AppServices._instance!;
