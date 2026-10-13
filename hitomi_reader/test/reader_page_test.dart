import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hitomi_api/hitomi_api.dart';
import 'package:hitomi_reader/pages/reader_page.dart';
import 'package:hitomi_reader/services/app_services.dart';
import 'package:hitomi_reader/services/crop.dart';
import 'package:hitomi_reader/services/http_client.dart';
import 'package:hitomi_reader/services/settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _gallery = Gallery.fromJson({
  'id': '42',
  'title': '测试画廊',
  'type': 'manga',
  'files': [
    for (var i = 0; i < 20; i++)
      {
        'hash': 'abcdef$i$i$i',
        'name': '$i.webp',
        'width': 1000,
        'height': 1400,
      },
  ],
});

void main() {
  late Directory directory;

  /// 右下角页码（菜单隐藏时显示）。
  Finder info(String label) => find.descendant(
    of: find.byKey(const ValueKey('reader-info')),
    matching: find.text(label),
  );

  Finder page(int index) => find.byKey(ValueKey('reader-page-$index'));

  /// 图片请求一律返回 404，页面停留在加载中或失败状态即可，测试只关心翻页逻辑。
  Future<void> pumpReader(
    WidgetTester tester, {
    Size size = const Size(400, 800),
    bool guideShown = true,
    void Function(AppSettings settings)? configure,
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('reader_page_test');
      final settings = AppSettings(await SharedPreferences.getInstance());
      await AppServices.create(
        settings: settings,
        http: ProxyHttpClient(const ProxyConfig(mode: ProxyMode.direct)),
        client: MockClient((_) async => http.Response('', 404)),
        supportDirectory: Directory('${directory.path}/support'),
        cacheDirectory: Directory('${directory.path}/cache'),
        downloadDirectory: Directory('${directory.path}/downloads'),
      );
      settings
        ..readerGuideShown = guideShown
        ..readerMode = ReaderMode.leftToRight;
      configure?.call(settings);
    });
    await tester.pumpWidget(MaterialApp(home: ReaderPage(gallery: _gallery)));
    await tester.pump();
  }

  Future<void> tearDownReader(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1)); // 让保存阅读记录的定时器触发
    await tester.runAsync(() async {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // 阅读记录可能还在写入，临时目录留着也无妨
      }
    });
  }

  /// 底部面板的进入动画在下一帧才开始。
  Future<void> settleSheet(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// 翻页动画结束后，页码在下一帧更新。
  Future<void> settlePage(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 单击需要等双击判定超时后才生效。
  Future<void> tap(WidgetTester tester, Offset position) async {
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('横屏自动双页：封面单独，之后两页并排，从右到左时第一页在右边', (tester) async {
    await pumpReader(tester, size: const Size(1200, 800));
    expect(page(0), findsOneWidget);
    expect(info('1 / 20'), findsOneWidget);

    await tap(tester, const Offset(1150, 400)); // 右侧：下一页
    expect(page(1), findsOneWidget);
    expect(page(2), findsOneWidget);
    expect(info('2-3 / 20'), findsOneWidget);
    expect(
      tester.getCenter(page(1)).dx,
      lessThan(tester.getCenter(page(2)).dx),
    );

    // 切换到从右到左：同一屏，页面左右互换
    services.settings.readerMode = ReaderMode.rightToLeft;
    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(), // 重新创建阅读页
        home: ReaderPage(gallery: _gallery, initialPage: 1),
      ),
    );
    await tester.pump();
    expect(info('2-3 / 20'), findsOneWidget);
    expect(
      tester.getCenter(page(1)).dx,
      greaterThan(tester.getCenter(page(2)).dx),
    );
    // 从右到左时点左侧是下一页
    await tap(tester, const Offset(50, 400));
    expect(info('4-5 / 20'), findsOneWidget);
    await tearDownReader(tester);
  });

  testWidgets('竖屏自动单页；设置为双页后立即生效并停留在当前页', (tester) async {
    await pumpReader(tester);
    await tap(tester, const Offset(390, 400));
    await tap(tester, const Offset(390, 400));
    expect(info('3 / 20'), findsOneWidget);
    expect(page(3), findsNothing);

    services.settings.pageLayout = PageLayout.double;
    await tester.pump();
    await tester.pump();
    // 第 3 页（下标 2）属于 [1, 2] 这一屏
    expect(page(1), findsOneWidget);
    expect(page(2), findsOneWidget);
    expect(info('3 / 20'), findsNothing);
    await tearDownReader(tester);
  });

  testWidgets('开启音量键翻页后音量减翻到下一页，关闭时交还系统', (tester) async {
    await pumpReader(tester);
    var handled = await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown);
    expect(handled, isFalse, reason: '未开启时应当由系统调节音量');
    await settlePage(tester);
    expect(info('1 / 20'), findsOneWidget);

    services.settings.volumeKeys = true;
    await tester.pump();
    handled = await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown);
    expect(handled, isTrue);
    await settlePage(tester);
    expect(info('2 / 20'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeUp);
    await settlePage(tester);
    expect(info('1 / 20'), findsOneWidget);

    services.settings.volumeKeysInverted = true;
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeUp);
    await settlePage(tester);
    expect(info('2 / 20'), findsOneWidget);
    await tearDownReader(tester);
  });

  testWidgets('缩略图跳页', (tester) async {
    await pumpReader(tester);
    await tap(tester, const Offset(200, 400)); // 中间：显示菜单
    await tester.tap(find.text('缩略图'));
    await settleSheet(tester);
    expect(find.byKey(const ValueKey('thumbnail:4')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('thumbnail:4')));
    await settleSheet(tester);
    expect(page(4), findsOneWidget);
    expect(info('5 / 20'), findsOneWidget);
    await tearDownReader(tester);
  });

  testWidgets('自动翻页按间隔前进，可以停止', (tester) async {
    await pumpReader(
      tester,
      configure: (settings) => settings.autoTurnSeconds = 2,
    );
    await tap(tester, const Offset(200, 400));
    await tester.tap(find.text('自动翻页'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(info('1 / 20'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(info('2 / 20'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(info('3 / 20'), findsOneWidget);

    await tap(tester, const Offset(200, 400));
    await tester.tap(find.text('停止翻页'));
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('3 / 20'), findsWidgets);
    await tearDownReader(tester);
  });

  testWidgets('竖向模式双指缩放不会滚动列表，放大后单指仍能上下滚动', (tester) async {
    await pumpReader(
      tester,
      configure: (settings) => settings.readerMode = ReaderMode.vertical,
    );
    ScrollController scroll() =>
        tester.widget<ListView>(find.byType(ListView)).controller!;
    double scale() => tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!
        .value
        .getMaxScaleOnAxis();
    expect(scroll().offset, 0);

    // 两根手指几乎同时按下，一根不动、另一根向下移动（列表最容易抢走手势的情况）
    final first = await tester.startGesture(const Offset(200, 380));
    final second = await tester.startGesture(const Offset(200, 420));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await second.moveBy(const Offset(0, 15));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await first.up();
    await second.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(scale(), greaterThan(1.5));
    expect(scroll().offset, 0, reason: '缩放时列表不应滚动');

    await tester.dragFrom(const Offset(200, 600), const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 500));
    expect(scroll().offset, greaterThan(50));
    expect(scale(), greaterThan(1.5));
    await tearDownReader(tester);
  });

  testWidgets('第一次打开显示点击区域说明，点击后不再显示', (tester) async {
    await pumpReader(tester, guideShown: false);
    final guide = find.byKey(const ValueKey('reader-tap-guide'));
    expect(guide, findsOneWidget);

    // 点击只关闭说明，不翻页
    await tester.tapAt(const Offset(390, 400));
    await tester.pump();
    expect(guide, findsNothing);
    expect(services.settings.readerGuideShown, isTrue);
    await tester.pump(const Duration(milliseconds: 500));
    expect(info('1 / 20'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        home: ReaderPage(gallery: _gallery),
      ),
    );
    await tester.pump();
    expect(guide, findsNothing);
    await tearDownReader(tester);
  });

  testWidgets('阅读设置面板可以打开并切换选项', (tester) async {
    await pumpReader(tester);
    await tap(tester, const Offset(200, 400));
    await tester.tap(find.text('阅读设置'));
    await settleSheet(tester);
    expect(find.text('每屏页数'), findsOneWidget);

    await tester.tap(find.text('双页'));
    await tester.pump();
    expect(services.settings.pageLayout, PageLayout.double);

    final list = find.descendant(
      of: find.byType(DraggableScrollableSheet),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(find.text('音量键翻页'), 100, scrollable: list);
    await tester.tap(find.text('音量键翻页'));
    await tester.pump();
    expect(services.settings.volumeKeys, isTrue);
    // 开启后才出现“反转音量键”
    expect(find.text('反转音量键'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('预加载页数：3'),
      100,
      scrollable: list,
    );
    expect(tester.takeException(), isNull);
    await tearDownReader(tester);
  });

  for (final mode in ReaderMode.values) {
    testWidgets('呼出菜单只露出状态栏，画面和菜单栏都不重新布局（${mode.shortLabel}）', (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      void systemBars({double top = 0, double bottom = 0}) {
        final padding = FakeViewPadding(top: top, bottom: bottom);
        tester.view
          ..viewPadding = padding
          ..padding = padding;
      }

      // 进入阅读页之前状态栏和导航栏都可见
      systemBars(top: 30, bottom: 40);
      await pumpReader(
        tester,
        configure: (settings) => settings.readerMode = mode,
      );
      final vertical = mode == ReaderMode.vertical;
      if (vertical) {
        tester.widget<ListView>(find.byType(ListView)).controller!.jumpTo(1000);
        await tester.pump();
      }
      // 竖向模式下第 2 页在屏幕顶部附近
      Rect pageRect() => tester.getRect(page(vertical ? 1 : 0));
      Size bar(Finder inside) => tester.getSize(
        find.ancestor(of: inside, matching: find.byType(Material)).first,
      );
      final pageBefore = pageRect();
      final top = bar(find.byType(BackButton));
      final bottom = bar(find.text('缩略图'));
      expect(top.height, kToolbarHeight + 30);

      // 进入全屏后系统栏隐藏，挖孔屏顶部仍保留一小段边距
      systemBars(top: 12);
      await tester.pump();
      expect(pageRect(), pageBefore);

      calls.clear();
      await tap(tester, const Offset(200, 400)); // 显示菜单
      final modes = calls.where(
        (call) => call.method.startsWith('SystemChrome.setEnabledSystemUI'),
      );
      expect(
        modes.map((call) => call.arguments),
        isNot(contains('SystemUiMode.edgeToEdge')),
        reason: 'edgeToEdge 会改变窗口适配系统栏的方式，导致整个画面重新布局',
      );
      expect(modes.last.method, 'SystemChrome.setEnabledSystemUIOverlays');
      expect(modes.last.arguments, ['SystemUiOverlay.top']);

      // 状态栏出现：菜单栏高度不变，画面不动
      systemBars(top: 30);
      await tester.pump();
      expect(pageRect(), pageBefore, reason: '状态栏出现时画面不应移动');
      expect(bar(find.byType(BackButton)), top);
      expect(bar(find.text('缩略图')), bottom);

      calls.clear();
      await tap(tester, const Offset(200, 400)); // 收起菜单
      expect(calls.last.arguments, 'SystemUiMode.immersiveSticky');
      systemBars(top: 12);
      await tester.pump();
      expect(pageRect(), pageBefore);
      await tearDownReader(tester);
    });
  }

  testWidgets('菜单动画：顶栏从上方滑下，底栏从屏幕底部升起', (tester) async {
    await pumpReader(tester);
    Rect bar(Finder inside) => tester.getRect(
      find.ancestor(of: inside, matching: find.byType(Material)).first,
    );

    /// 单击在双击判定超时后生效，动画在下一帧开始，再走到一半。
    Future<void> tapAndHalfway() async {
      await tester.tapAt(const Offset(200, 400));
      await tester.pump(const Duration(milliseconds: 310));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tapAndHalfway(); // 显示菜单
    final topShowing = bar(find.byType(BackButton));
    final bottomShowing = bar(find.text('缩略图'));
    await tester.pump(const Duration(milliseconds: 300));
    final top = bar(find.byType(BackButton));
    final bottom = bar(find.text('缩略图'));
    expect(top.top, 0);
    expect(bottom.bottom, 800);
    expect(topShowing.top, inExclusiveRange(-top.height, 0));
    expect(
      bottomShowing.top,
      inExclusiveRange(bottom.top, 800),
      reason: '底栏应从屏幕底部升起，而不是从上方落下',
    );

    await tapAndHalfway(); // 收起菜单
    expect(bar(find.byType(BackButton)).top, inExclusiveRange(-top.height, 0));
    expect(bar(find.text('缩略图')).top, inExclusiveRange(bottom.top, 800));
    await tester.pump(const Duration(milliseconds: 300));
    expect(bar(find.byType(BackButton)).bottom, lessThanOrEqualTo(0));
    expect(bar(find.text('缩略图')).top, greaterThanOrEqualTo(800));
    await tearDownReader(tester);
  });

  testWidgets('长按或右键页面弹出菜单：保存图片、重新加载', (tester) async {
    await pumpReader(tester);
    await tester.longPress(page(0));
    await settleSheet(tester);
    expect(find.text('第 1 页'), findsOneWidget);
    expect(find.text('保存图片'), findsOneWidget);
    expect(find.text('重新加载本页'), findsOneWidget);
    expect(info('1 / 20'), findsOneWidget, reason: '长按不应翻页');

    await tester.tapAt(const Offset(200, 50)); // 点遮罩关闭
    await settleSheet(tester);
    expect(find.text('保存图片'), findsNothing);

    await tester.tap(
      page(0),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await settleSheet(tester);
    expect(find.text('保存图片'), findsOneWidget);
    await tearDownReader(tester);
  });

  testWidgets('竖向模式裁切白边：上方页面高度变化时画面不跳动', (tester) async {
    await pumpReader(
      tester,
      configure: (settings) => settings
        ..readerMode = ReaderMode.vertical
        ..cropBorders = true,
    );
    final scroll = tester.widget<ListView>(find.byType(ListView)).controller!;
    // 400 宽时每页 560 高；停在第 6 页往下 100 像素处
    scroll.jumpTo(5 * 560 + 100);
    await tester.pump();
    expect(info('6 / 20'), findsOneWidget);

    const insets = CropInsets(0.1, 0.05, 0.1, 0.05);
    final cropped = 400 / insets.croppedAspectRatio(1000 / 1400);
    for (var i = 0; i < 5; i++) {
      services.crops.put('abcdef$i$i$i', insets);
    }
    await tester.pump();
    expect(scroll.offset, closeTo(5 * cropped + 100, 0.5));
    expect(info('6 / 20'), findsOneWidget);

    // 当前页本身变化：停在页内相同比例的位置
    services.crops.put('abcdef555', insets);
    await tester.pump();
    expect(scroll.offset, closeTo(5 * cropped + 100 / 560 * cropped, 0.5));

    // 下方页面的变化不影响当前位置
    final offset = scroll.offset;
    services.crops.put('abcdef666', insets);
    await tester.pump();
    expect(scroll.offset, closeTo(offset, 0.01));
    final pageHeight = tester.getSize(page(6)).height;
    expect(pageHeight, closeTo(cropped, 0.5));
    await tearDownReader(tester);
  });
}
