import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:hitomi_api/hitomi_api.dart';
import 'package:http/http.dart' as http;

import '../utils/pool.dart';

enum ImageKind {
  /// 所有页面都有的小缩略图。
  thumbnailSmall,

  /// 仅首页和中间页有的大缩略图，其他页面会退回小缩略图。
  thumbnailBig,

  /// 原图。
  full,
}

class HttpStatusException implements Exception {
  const HttpStatusException(this.statusCode, this.url);

  final int statusCode;
  final String url;

  @override
  String toString() => 'HTTP $statusCode';
}

typedef ProgressCallback = void Function(int received, int? total);

/// 负责下载图片并缓存到磁盘。
class ImageLoader {
  ImageLoader(this._hitomi, this._client, this.cacheDirectory);

  final Hitomi _hitomi;
  final http.Client _client;
  final Directory cacheDirectory;

  /// 同时进行的图片下载数量上限，超时只从真正开始请求时计算。
  final Pool _pool = Pool(10, lifo: true);

  static String cacheKey(GalleryImage image, ImageKind kind) {
    final suffix = switch (kind) {
      ImageKind.thumbnailSmall => 's',
      ImageKind.thumbnailBig => image.hasThumbnail ? 'b' : 's',
      ImageKind.full => 'f',
    };
    return '${image.hash}_$suffix.webp';
  }

  File cacheFile(GalleryImage image, ImageKind kind) =>
      File('${cacheDirectory.path}/${cacheKey(image, kind)}');

  /// 依次尝试：本地下载文件 → 磁盘缓存 → 网络。
  Future<Uint8List> load(
    GalleryImage image,
    ImageKind kind, {
    String? localFile,
    ProgressCallback? onProgress,
  }) async {
    if (localFile != null) {
      final file = File(localFile);
      if (await file.exists()) return file.readAsBytes();
    }

    final cached = cacheFile(image, kind);
    if (await cached.exists()) {
      try {
        final bytes = await cached.readAsBytes();
        if (bytes.isNotEmpty) return bytes;
      } on FileSystemException {
        // 文件可能正在被清理，继续走网络。
      }
    }

    final bytes = await download(image, kind, onProgress: onProgress);
    unawaited(_writeCache(cached, bytes));
    return bytes;
  }

  Future<void> _writeCache(File file, Uint8List bytes) async {
    try {
      await cacheDirectory.create(recursive: true);
      final temp = File(
        '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
    } on FileSystemException catch (error) {
      debugPrint('写入图片缓存失败: $error');
    }
  }

  /// 直接从网络下载，不经过缓存。
  ///
  /// gg.js 中的路径前缀会定期变化，原图返回 404 时会强制刷新后重试一次。
  Future<Uint8List> download(
    GalleryImage image,
    ImageKind kind, {
    ProgressCallback? onProgress,
  }) async {
    switch (kind) {
      case ImageKind.thumbnailSmall:
        return fetchBytes(image.thumbnailUrl(), onProgress: onProgress);
      case ImageKind.thumbnailBig:
        return fetchBytes(
          image.thumbnailUrl(
            size: image.hasThumbnail ? ThumbnailSize.big : ThumbnailSize.small,
          ),
          onProgress: onProgress,
        );
      case ImageKind.full:
        final context = await _hitomi.imageContext();
        try {
          return await fetchBytes(
            image.fullUrl(context),
            onProgress: onProgress,
          );
        } on HttpStatusException catch (error) {
          if (error.statusCode != 404) rethrow;
          final fresh = await _hitomi.imageContext(forceRefresh: true);
          return fetchBytes(image.fullUrl(fresh), onProgress: onProgress);
        }
    }
  }

  Future<Uint8List> fetchBytes(String url, {ProgressCallback? onProgress}) =>
      _pool.run(() => _fetchBytes(url, onProgress));

  Future<Uint8List> _fetchBytes(
    String url,
    ProgressCallback? onProgress,
  ) async {
    final request = http.Request('GET', Uri.parse(url))
      ..headers.addAll(defaultHeaders);
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      unawaited(response.stream.drain<void>().catchError((_) {}));
      throw HttpStatusException(response.statusCode, url);
    }
    final total = response.contentLength;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      builder.add(chunk);
      onProgress?.call(builder.length, total);
    }
    return builder.takeBytes();
  }

  /// 缓存占用的字节数。
  Future<int> cacheSize() {
    final path = cacheDirectory.path;
    return Isolate.run(() {
      final directory = Directory(path);
      if (!directory.existsSync()) return 0;
      var size = 0;
      for (final entity in directory.listSync()) {
        if (entity is File) size += entity.lengthSync();
      }
      return size;
    });
  }

  /// 缓存超过 [maxBytes] 时删除最旧的文件，直到降到上限的 80%。
  Future<void> trimCache(int maxBytes) {
    final path = cacheDirectory.path;
    return Isolate.run(() {
      final directory = Directory(path);
      if (!directory.existsSync()) return;
      final files = <(File, int, DateTime)>[];
      var size = 0;
      for (final entity in directory.listSync()) {
        if (entity is! File) continue;
        final stat = entity.statSync();
        files.add((entity, stat.size, stat.modified));
        size += stat.size;
      }
      if (size <= maxBytes) return;
      files.sort((a, b) => a.$3.compareTo(b.$3));
      final target = maxBytes * 0.8;
      for (final (file, length, _) in files) {
        if (size <= target) break;
        try {
          file.deleteSync();
          size -= length;
        } on FileSystemException {
          // 忽略正在使用的文件。
        }
      }
    });
  }

  Future<void> clearCache() async {
    if (await cacheDirectory.exists()) {
      await cacheDirectory.delete(recursive: true);
    }
    await cacheDirectory.create(recursive: true);
  }
}
