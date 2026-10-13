import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../services/app_services.dart';
import '../services/image_loader.dart';

/// 通过 [ImageLoader] 加载的 hitomi 图片（带 Referer、代理与磁盘缓存）。
@immutable
class HitomiImageProvider extends ImageProvider<HitomiImageProvider> {
  const HitomiImageProvider(
    this.image,
    this.kind, {
    this.localFile,
    this.decodeWidth,
    this.attempt = 0,
    this.detectCrop = false,
  });

  final GalleryImage image;
  final ImageKind kind;

  /// 已下载到本地的文件路径，存在时优先使用。
  final String? localFile;

  /// 解码宽度（物理像素），原图更窄时按原尺寸解码。
  ///
  /// 在 provider 内部缩放而不是包一层 [ResizeImage]，这样缓存键始终是 provider 本身，
  /// 加载失败时可以准确地从 [ImageCache] 中移除。
  final int? decodeWidth;

  /// 用于重试：不同的 attempt 会生成新的缓存键。
  final int attempt;

  /// 加载时顺便检测白边（结果写入 [AppServices.crops]），在图片显示前完成，页面不会跳动。
  final bool detectCrop;

  @override
  Future<HitomiImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    HitomiImageProvider key,
    ImageDecoderCallback decode,
  ) {
    final chunks = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode, chunks).whenComplete(chunks.close),
      chunkEvents: chunks.stream,
      scale: 1,
      debugLabel: '${key.kind.name}:${key.image.hash}',
      informationCollector: () => [
        DiagnosticsProperty<HitomiImageProvider>('Image provider', this),
      ],
    );
  }

  static Future<ui.Codec> _load(
    HitomiImageProvider key,
    ImageDecoderCallback decode,
    StreamController<ImageChunkEvent> chunks,
  ) async {
    try {
      final bytes = await services.images.load(
        key.image,
        key.kind,
        localFile: key.localFile,
        onProgress: (received, total) {
          if (!chunks.isClosed) {
            chunks.add(
              ImageChunkEvent(
                cumulativeBytesLoaded: received,
                expectedTotalBytes: total,
              ),
            );
          }
        },
      );
      if (key.detectCrop) {
        try {
          await services.crops.detect(key.image.hash, bytes);
        } catch (error) {
          debugPrint('白边检测失败: $error');
        }
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final width = key.decodeWidth;
      return await decode(
        buffer,
        getTargetSize: width == null
            ? null
            : (intrinsicWidth, _) => intrinsicWidth > width
                  ? ui.TargetImageSize(width: width)
                  : const ui.TargetImageSize(),
      );
    } catch (_) {
      // ImageCache 不会移除失败的图片，不处理的话之后同一键会一直返回失败。
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is HitomiImageProvider &&
      other.image.hash == image.hash &&
      other.kind == kind &&
      other.localFile == localFile &&
      other.decodeWidth == decodeWidth &&
      other.attempt == attempt &&
      other.detectCrop == detectCrop;

  @override
  int get hashCode => Object.hash(
    image.hash,
    kind,
    localFile,
    decodeWidth,
    attempt,
    detectCrop,
  );

  @override
  String toString() => 'HitomiImageProvider(${kind.name}, ${image.hash})';
}

/// 显示 hitomi 图片，带加载进度与失败重试。
class HitomiImage extends StatefulWidget {
  const HitomiImage({
    super.key,
    required this.image,
    this.kind = ImageKind.thumbnailBig,
    this.localFile,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.decodeWidth,
    this.showProgress = false,
    this.alignment = Alignment.center,
  });

  final GalleryImage image;
  final ImageKind kind;
  final String? localFile;
  final BoxFit fit;
  final double? width;
  final double? height;

  /// 解码宽度（物理像素），用于降低大图的内存占用。
  final int? decodeWidth;
  final bool showProgress;
  final Alignment alignment;

  /// 构建与 [HitomiImage] 相同的 provider，用于预加载。
  static ImageProvider provider(
    GalleryImage image,
    ImageKind kind, {
    String? localFile,
    int? decodeWidth,
    int attempt = 0,
    bool detectCrop = false,
  }) => HitomiImageProvider(
    image,
    kind,
    localFile: localFile,
    decodeWidth: decodeWidth,
    attempt: attempt,
    detectCrop: detectCrop,
  );

  @override
  State<HitomiImage> createState() => _HitomiImageState();
}

class _HitomiImageState extends State<HitomiImage> {
  int _attempt = 0;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Image(
      image: HitomiImage.provider(
        widget.image,
        widget.kind,
        localFile: widget.localFile,
        decodeWidth: widget.decodeWidth,
        attempt: _attempt,
      ),
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      alignment: widget.alignment,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) return child;
        return _placeholder(colors, null);
      },
      loadingBuilder: widget.showProgress
          ? (context, child, progress) {
              if (progress == null) return child;
              final total = progress.expectedTotalBytes;
              return _placeholder(
                colors,
                total == null || total == 0
                    ? null
                    : progress.cumulativeBytesLoaded / total,
              );
            }
          : null,
      errorBuilder: (context, error, stackTrace) => _error(colors, error),
    );
  }

  Widget _placeholder(ColorScheme colors, double? progress) => Container(
    width: widget.width,
    height: widget.height,
    color: colors.surfaceContainerHighest,
    alignment: Alignment.center,
    child: widget.showProgress
        ? SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(value: progress, strokeWidth: 3),
          )
        : null,
  );

  Widget _error(ColorScheme colors, Object error) => Container(
    width: widget.width,
    height: widget.height,
    color: colors.surfaceContainerHighest,
    alignment: Alignment.center,
    child: InkWell(
      onTap: () => setState(() => _attempt++),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, color: colors.outline),
            if (widget.showProgress) ...[
              const SizedBox(height: 8),
              Text(
                '加载失败，点击重试\n$error',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.outline, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
