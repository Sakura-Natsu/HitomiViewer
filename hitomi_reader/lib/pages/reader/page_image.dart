import 'package:flutter/material.dart';

import '../../services/crop.dart';

/// 阅读器中的一页：加载中显示页码与进度，失败时可重试。
class ReaderPageImage extends StatelessWidget {
  const ReaderPageImage({
    super.key,
    required this.provider,
    required this.pageNumber,
    required this.onRetry,
    this.alignment = Alignment.center,
    this.aspectRatio = 0,
    this.crop,
  });

  final ImageProvider provider;
  final int pageNumber;
  final VoidCallback onRetry;

  /// 双页时左右两页向中缝对齐。
  final Alignment alignment;

  /// 原图宽高比（来自画廊信息），裁切白边时用来计算位置；未知时为 0。
  final double aspectRatio;

  /// 图片显示时读取白边检测结果（检测在图片加载完成前就已写入缓存）。
  final CropInsets? Function()? crop;

  @override
  Widget build(BuildContext context) {
    return Image(
      image: provider,
      fit: BoxFit.contain,
      alignment: alignment,
      gaplessPlayback: true,
      loadingBuilder: (context, child, progress) => progress == null
          ? child
          : _ImageProgress(progress: progress, pageNumber: pageNumber),
      frameBuilder: (context, child, frame, sync) {
        if (frame == null && !sync) {
          return _ImageProgress(pageNumber: pageNumber);
        }
        final insets = crop?.call();
        if (insets == null || insets.isZero || aspectRatio <= 0) return child;
        return CroppedBox(
          aspectRatio: aspectRatio,
          insets: insets,
          alignment: alignment,
          child: child,
        );
      },
      errorBuilder: (context, error, _) =>
          _ImageError(pageNumber: pageNumber, error: error, onRetry: onRetry),
    );
  }
}

/// 只显示图片中去掉 [insets] 后的部分，并按 [BoxFit.contain] 放进可用空间。
///
/// [child] 会被放大到整张图的尺寸（宽高比为 [aspectRatio]），再裁到可见区域。
class CroppedBox extends StatelessWidget {
  const CroppedBox({
    super.key,
    required this.aspectRatio,
    required this.insets,
    required this.child,
    this.alignment = Alignment.center,
  });

  final double aspectRatio;
  final CropInsets insets;
  final Alignment alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxWidth = constraints.maxWidth;
        final boxHeight = constraints.maxHeight;
        if (!boxWidth.isFinite || !boxHeight.isFinite) return child;
        final region = insets.croppedAspectRatio(aspectRatio);
        var width = boxWidth;
        var height = boxWidth / region;
        if (height > boxHeight) {
          height = boxHeight;
          width = boxHeight * region;
        }
        final fullWidth = width / (1 - insets.left - insets.right);
        final fullHeight = height / (1 - insets.top - insets.bottom);
        return Stack(
          children: [
            Positioned(
              left: (boxWidth - width) * (alignment.x + 1) / 2,
              top: (boxHeight - height) * (alignment.y + 1) / 2,
              width: width,
              height: height,
              child: ClipRect(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: -insets.left * fullWidth,
                      top: -insets.top * fullHeight,
                      width: fullWidth,
                      height: fullHeight,
                      child: child,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ImageProgress extends StatelessWidget {
  const _ImageProgress({required this.pageNumber, this.progress});

  final int pageNumber;
  final ImageChunkEvent? progress;

  @override
  Widget build(BuildContext context) {
    final total = progress?.expectedTotalBytes;
    final value = total == null || total == 0
        ? null
        : progress!.cumulativeBytesLoaded / total;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: CircularProgressIndicator(
              value: value,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            value == null
                ? '$pageNumber'
                : '$pageNumber · ${(value * 100).toStringAsFixed(0)}%',
            style: const TextStyle(color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

class _ImageError extends StatelessWidget {
  const _ImageError({
    required this.pageNumber,
    required this.error,
    required this.onRetry,
  });

  final int pageNumber;
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    // 竖向模式下宽图的高度可能很小，内容放不下时整体缩小，避免溢出
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          width: 280,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.broken_image_outlined,
                color: Colors.white54,
                size: 40,
              ),
              const SizedBox(height: 8),
              Text(
                '第 $pageNumber 页加载失败',
                style: const TextStyle(color: Colors.white70),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 4,
                ),
                child: Text(
                  '$error',
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
      ),
    );
  }
}
