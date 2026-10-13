import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hitomi_reader/pages/reader/page_image.dart';
import 'package:hitomi_reader/services/crop.dart';

/// 生成 [width]×[height] 的 RGBA 像素：背景色 [background]，[content] 区域填 [ink]。
Uint8List _pixels(
  int width,
  int height, {
  required Rect content,
  int background = 255,
  int ink = 40,
}) {
  final data = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final inside = content.contains(Offset(x + 0.5, y + 0.5));
      final value = inside ? ink : background;
      final i = (y * width + x) * 4;
      data[i] = data[i + 1] = data[i + 2] = value;
      data[i + 3] = 255;
    }
  }
  return data;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('detectCropInsets', () {
    test('四周白边：左右各 10%，上下各 5%，往回留一个像素', () {
      final insets = detectCropInsets(
        _pixels(200, 280, content: const Rect.fromLTRB(20, 14, 180, 266)),
        200,
        280,
      );
      expect(insets.left, closeTo(19 / 200, 1e-9));
      expect(insets.right, closeTo(19 / 200, 1e-9));
      expect(insets.top, closeTo(13 / 280, 1e-9));
      expect(insets.bottom, closeTo(13 / 280, 1e-9));
    });

    test('黑边也能裁掉', () {
      final insets = detectCropInsets(
        _pixels(
          200,
          280,
          content: const Rect.fromLTRB(30, 0, 170, 280),
          background: 0,
          ink: 200,
        ),
        200,
        280,
      );
      expect(insets.left, closeTo(29 / 200, 1e-9));
      expect(insets.right, closeTo(29 / 200, 1e-9));
      expect(insets.top, 0);
      expect(insets.bottom, 0);
    });

    test('白边里有少量噪点（扫描灰尘）仍然裁切', () {
      final data = _pixels(
        200,
        280,
        content: const Rect.fromLTRB(20, 20, 180, 260),
      );
      // 上边距里零星的黑点
      for (final x in [50, 120]) {
        final i = (5 * 200 + x) * 4;
        data[i] = data[i + 1] = data[i + 2] = 0;
      }
      expect(detectCropInsets(data, 200, 280).top, greaterThan(0.05));
    });

    test('边上的页码不会挡住裁切', () {
      final data = _pixels(
        200,
        280,
        content: const Rect.fromLTRB(20, 14, 180, 266),
      );
      // 左下角留白里 4×6 像素的页码
      for (var y = 270; y < 276; y++) {
        for (var x = 5; x < 9; x++) {
          final i = (y * 200 + x) * 4;
          data[i] = data[i + 1] = data[i + 2] = 0;
        }
      }
      final insets = detectCropInsets(data, 200, 280);
      expect(insets.left, closeTo(19 / 200, 1e-9));
      expect(insets.bottom, closeTo(13 / 280, 1e-9));
    });

    test('大片留白中间的小图（裁完不到一半）不裁', () {
      expect(
        detectCropInsets(
          _pixels(200, 280, content: const Rect.fromLTRB(50, 40, 150, 160)),
          200,
          280,
        ),
        CropInsets.zero,
      );
    });

    test('暗色画面不当作黑边', () {
      // 深灰（不是纯黑）背景
      expect(
        detectCropInsets(
          _pixels(
            200,
            280,
            content: const Rect.fromLTRB(30, 30, 170, 250),
            background: 28,
            ink: 200,
          ),
          200,
          280,
        ),
        CropInsets.zero,
      );
    });

    test('内容贴边（满版彩图）不裁', () {
      final data = _pixels(
        200,
        280,
        content: const Rect.fromLTRB(0, 0, 200, 280),
      );
      expect(detectCropInsets(data, 200, 280), CropInsets.zero);
    });

    test('边距太小（< 2%）忽略，避免页面大小来回微调', () {
      final insets = detectCropInsets(
        _pixels(200, 280, content: const Rect.fromLTRB(2, 30, 198, 250)),
        200,
        280,
      );
      expect(insets.left, 0);
      expect(insets.right, 0);
      expect(insets.top, greaterThan(0.09));
    });

    test('空白页和几乎空白的页不裁', () {
      expect(
        detectCropInsets(_pixels(200, 280, content: Rect.zero), 200, 280),
        CropInsets.zero,
      );
      expect(
        detectCropInsets(
          _pixels(200, 280, content: const Rect.fromLTRB(90, 120, 110, 140)),
          200,
          280,
        ),
        CropInsets.zero,
      );
    });

    test('裁切后的宽高比', () {
      const insets = CropInsets(0.1, 0.05, 0.1, 0.05);
      expect(insets.croppedAspectRatio(0.7), closeTo(0.7 * 0.8 / 0.9, 1e-9));
    });
  });

  test('CropCache 解码真实图片字节后检测白边并缓存', () async {
    // 1000×1400 的白底图片，中间 800×1260 是深色内容
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..drawRect(
        const Rect.fromLTWH(0, 0, 1000, 1400),
        Paint()..color = Colors.white,
      )
      ..drawRect(
        const Rect.fromLTWH(100, 70, 800, 1260),
        Paint()..color = const Color(0xFF333333),
      );
    final image = await recorder.endRecording().toImage(1000, 1400);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();

    final cache = CropCache();
    var notified = 0;
    cache.addListener(() => notified++);
    final insets = await cache.detect('page', png!.buffer.asUint8List());
    // 缩小到 200 宽检测，误差在一两个像素（1%）以内
    expect(insets.left, closeTo(0.1, 0.01));
    expect(insets.right, closeTo(0.1, 0.01));
    expect(insets.top, closeTo(0.05, 0.01));
    expect(insets.bottom, closeTo(0.05, 0.01));
    expect(cache.peek('page'), insets);
    expect(notified, 1);

    // 第二次直接用缓存
    expect(await cache.detect('page', Uint8List(0)), insets);
    cache.forget('page');
    expect(cache.peek('page'), isNull);
  });

  testWidgets('CroppedBox 只显示裁切后的区域，并按 contain 放进可用空间', (tester) async {
    const key = ValueKey('image');
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 300,
            height: 500,
            child: CroppedBox(
              aspectRatio: 0.7,
              insets: CropInsets(0.1, 0.05, 0.1, 0.05),
              child: ColoredBox(key: key, color: Colors.red),
            ),
          ),
        ),
      ),
    );
    final box = tester.getRect(find.byType(CroppedBox));
    expect(box.size, const Size(300, 500));
    // 可见区域宽高比 0.7 × 0.8 / 0.9 ≈ 0.622，比 300×500 宽，所以占满宽度
    const regionHeight = 300 / (0.7 * 0.8 / 0.9);
    const fullWidth = 300 / 0.8;
    const fullHeight = regionHeight / 0.9;
    final image = tester.getRect(find.byKey(key));
    expect(image.width, closeTo(fullWidth, 0.01));
    expect(image.height, closeTo(fullHeight, 0.01));
    expect(image.left - box.left, closeTo(-0.1 * fullWidth, 0.01));
    expect(
      image.top - box.top,
      closeTo((500 - regionHeight) / 2 - 0.05 * fullHeight, 0.01),
    );
    // 可见部分被裁到区域内
    final clip = tester.getRect(find.byType(ClipRect));
    expect(clip.width, closeTo(300, 0.01));
    expect(clip.height, closeTo(regionHeight, 0.01));
  });

  testWidgets('CroppedBox 双页时向中缝对齐', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 400,
            height: 560,
            child: CroppedBox(
              aspectRatio: 0.7,
              insets: CropInsets(0.1, 0.05, 0.1, 0.05),
              alignment: Alignment.centerRight,
              child: SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    final box = tester.getRect(find.byType(CroppedBox));
    final clip = tester.getRect(find.byType(ClipRect));
    // 高度受限：区域占满高度，宽度 560 × 0.622，靠右
    expect(clip.height, closeTo(560, 0.01));
    expect(clip.width, closeTo(560 * 0.7 * 0.8 / 0.9, 0.01));
    expect(clip.right, closeTo(box.right, 0.01));
  });

  testWidgets('ReaderPageImage 加载完成后按检测结果裁切显示', (tester) async {
    // 1000×1400 白底，中间深色内容（与上面的解码测试相同）
    late Uint8List png;
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder)
        ..drawRect(
          const Rect.fromLTWH(0, 0, 1000, 1400),
          Paint()..color = Colors.white,
        )
        ..drawRect(
          const Rect.fromLTWH(100, 70, 800, 1260),
          Paint()..color = const Color(0xFF333333),
        );
      final image = await recorder.endRecording().toImage(1000, 1400);
      png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
          .asUint8List();
      image.dispose();
    });
    final provider = MemoryImage(png);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => precacheImage(provider, tester.element(find.byType(SizedBox))),
    );

    Widget page(CropInsets? insets) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: 300,
          height: 500,
          child: ReaderPageImage(
            provider: provider,
            pageNumber: 1,
            onRetry: () {},
            aspectRatio: 1000 / 1400,
            crop: () => insets,
          ),
        ),
      ),
    );

    await tester.pumpWidget(page(null));
    expect(find.byType(CroppedBox), findsNothing);
    final plain = tester.getRect(find.byType(RawImage));

    const insets = CropInsets(0.1, 0.05, 0.1, 0.05);
    await tester.pumpWidget(page(insets));
    expect(find.byType(CroppedBox), findsOneWidget);
    final cropped = tester.getRect(find.byType(RawImage));
    // 裁掉白边后同样的空间里图片显示得更大，可见部分正好是内容区域
    expect(cropped.width, greaterThan(plain.width * 1.2));
    final clip = tester.getRect(find.byType(ClipRect));
    expect(clip.left - cropped.left, closeTo(0.1 * cropped.width, 0.5));
    expect(clip.top - cropped.top, closeTo(0.05 * cropped.height, 0.5));
  });
}
