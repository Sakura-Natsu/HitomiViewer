import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// 页面四周要裁掉的比例（0–1），相对于原图宽高。
@immutable
class CropInsets {
  const CropInsets(this.left, this.top, this.right, this.bottom);

  static const CropInsets zero = CropInsets(0, 0, 0, 0);

  final double left;
  final double top;
  final double right;
  final double bottom;

  bool get isZero => left == 0 && top == 0 && right == 0 && bottom == 0;

  /// 裁切后剩余部分的宽高比，[aspectRatio] 为原图宽高比。
  double croppedAspectRatio(double aspectRatio) =>
      aspectRatio * (1 - left - right) / (1 - top - bottom);

  @override
  bool operator ==(Object other) =>
      other is CropInsets &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() =>
      'CropInsets(${[left, top, right, bottom].map((v) => v.toStringAsFixed(3)).join(', ')})';
}

/// 根据缩小后的 RGBA 像素找出四周的白边（或黑边）。
///
/// 先看最外一圈像素是否大多是接近白色（或纯黑）且不带颜色，确定背景色；
/// 再从四边向内逐行 / 逐列扫描，整行都是背景色就算边。每行允许 3% 的杂点，
/// 这样边上的页码、扫描灰尘不会挡住裁切（页码会一起被裁掉）。
/// 裁得太少（< 2%）的边忽略，避免页面大小来回微调；裁完剩不到一半（空白页、
/// 大片留白中间的小图）则不裁，否则画面会被放得很大。
/// 黑边要求接近纯黑，避免把暗色画面的阴影当成边。
CropInsets detectCropInsets(Uint8List rgba, int width, int height) {
  if (width < 8 || height < 8 || rgba.length < width * height * 4) {
    return CropInsets.zero;
  }
  bool white(int x, int y) {
    final i = (y * width + x) * 4;
    final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    return min(r, min(g, b)) >= 225 &&
        max(r, max(g, b)) - min(r, min(g, b)) < 30;
  }

  bool black(int x, int y) {
    final i = (y * width + x) * 4;
    return max(rgba[i], max(rgba[i + 1], rgba[i + 2])) <= 16;
  }

  // 最外一圈中背景色的比例
  double border(bool Function(int, int) test) {
    var hits = 0;
    for (var x = 0; x < width; x++) {
      if (test(x, 0)) hits++;
      if (test(x, height - 1)) hits++;
    }
    for (var y = 1; y < height - 1; y++) {
      if (test(0, y)) hits++;
      if (test(width - 1, y)) hits++;
    }
    return hits / (2 * width + 2 * (height - 2));
  }

  final bool Function(int, int) background;
  if (border(white) >= 0.6) {
    background = white;
  } else if (border(black) >= 0.6) {
    background = black;
  } else {
    return CropInsets.zero;
  }

  bool row(int y) {
    var misses = 0;
    final allowed = max(2, width * 3 ~/ 100);
    for (var x = 0; x < width; x++) {
      if (!background(x, y) && ++misses > allowed) return false;
    }
    return true;
  }

  bool column(int x) {
    var misses = 0;
    final allowed = max(2, height * 3 ~/ 100);
    for (var y = 0; y < height; y++) {
      if (!background(x, y) && ++misses > allowed) return false;
    }
    return true;
  }

  var top = 0;
  while (top < height && row(top)) {
    top++;
  }
  if (top >= height) return CropInsets.zero; // 整页空白
  var bottom = height - 1;
  while (bottom > top && row(bottom)) {
    bottom--;
  }
  var left = 0;
  while (left < width && column(left)) {
    left++;
  }
  var right = width - 1;
  while (right > left && column(right)) {
    right--;
  }

  // 往回留一个像素，缩小取样时内容边缘会变淡
  top = max(0, top - 1);
  left = max(0, left - 1);
  bottom = min(height - 1, bottom + 1);
  right = min(width - 1, right + 1);

  double edge(int pixels, int size) {
    final fraction = pixels / size;
    return fraction < 0.02 ? 0 : fraction;
  }

  final insets = CropInsets(
    edge(left, width),
    edge(top, height),
    edge(width - 1 - right, width),
    edge(height - 1 - bottom, height),
  );
  if (1 - insets.left - insets.right < 0.5 ||
      1 - insets.top - insets.bottom < 0.5) {
    return CropInsets.zero;
  }
  return insets;
}

/// 白边检测结果的缓存。检测在图片加载时完成（显示之前），阅读器按需读取。
class CropCache extends ChangeNotifier {
  /// 检测时缩小到的宽度，足够找出边界，解码也很快。
  static const int sampleWidth = 200;

  final Map<String, CropInsets> _results = {};

  CropInsets? peek(String hash) => _results[hash];

  /// 对图片字节做检测并缓存，已有结果时直接返回。
  Future<CropInsets> detect(String hash, Uint8List bytes) async {
    final cached = _results[hash];
    if (cached != null) return cached;
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: sampleWidth,
    );
    ui.Image? image;
    try {
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final insets = data == null
          ? CropInsets.zero
          : detectCropInsets(
              data.buffer.asUint8List(),
              image.width,
              image.height,
            );
      put(hash, insets);
      return insets;
    } finally {
      image?.dispose();
      codec.dispose();
    }
  }

  /// 丢弃结果（重新加载页面时），下次加载重新检测。
  void forget(String hash) => _results.remove(hash);

  @visibleForTesting
  void put(String hash, CropInsets insets) {
    if (_results[hash] == insets) return;
    _results[hash] = insets;
    notifyListeners();
  }
}
