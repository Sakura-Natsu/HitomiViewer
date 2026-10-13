import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hitomi_reader/widgets/floating_header.dart';

void main() {
  const statusBar = 24.0;
  final headerKey = GlobalKey<FloatingHeaderState>();

  Future<ScrollController> pumpList(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: statusBar);
    addTearDown(tester.view.reset);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FloatingHeader(
            key: headerKey,
            header: AppBar(
              primary: false,
              title: const Text('搜索栏'),
              bottom: const PreferredSize(
                preferredSize: Size.fromHeight(48),
                child: SizedBox(height: 48, child: Text('筛选栏')),
              ),
            ),
            body: Builder(
              builder: (context) => ListView.builder(
                controller: controller,
                padding: EdgeInsets.only(
                  top: FloatingHeader.topPaddingOf(context),
                ),
                itemCount: 200,
                itemExtent: 100,
                itemBuilder: (context, index) => Text('第 $index 项'),
              ),
            ),
          ),
        ),
      ),
    );
    return controller;
  }

  double hidden() => headerKey.currentState!.hiddenExtent;

  /// 手指慢慢拖动（不带惯性）再松开。
  Future<void> drag(WidgetTester tester, double dy) async {
    final gesture = await tester.startGesture(const Offset(200, 500));
    const steps = 10;
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(0, dy / steps));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 300)); // 停住，没有惯性
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 收起 / 展开动画
  }

  testWidgets('列表留出状态栏 + 顶栏的空间，第一项不被盖住', (tester) async {
    await pumpList(tester);
    expect(tester.getTopLeft(find.text('第 0 项')).dy, statusBar + 56 + 48);
    expect(tester.getTopLeft(find.text('搜索栏')).dy, greaterThan(statusBar));
    expect(hidden(), 0);
  });

  testWidgets('往下滑时顶栏跟着滑走，滑得再远，往上滑一点就完整出现', (tester) async {
    final controller = await pumpList(tester);
    const header = 56 + 48.0;

    // 往下滑一小段：顶栏跟着内容移动，第一项仍紧贴顶栏下沿
    final gesture = await tester.startGesture(const Offset(200, 500));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    final firstItem = tester.getTopLeft(find.text('第 0 项')).dy;
    expect(hidden(), closeTo(controller.offset, 0.01));
    expect(firstItem, closeTo(statusBar + header - hidden(), 0.01));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));

    // 往下滑很远：完全收起，不占浏览空间
    await drag(tester, -3000);
    expect(controller.offset, greaterThan(2000));
    expect(hidden(), header);
    expect(
      tester.getBottomLeft(find.text('筛选栏')).dy,
      lessThanOrEqualTo(statusBar),
    );

    // 在很深的位置往上轻轻滑一点就完整出现，不用回到顶部
    final deep = controller.offset;
    await drag(tester, 30);
    expect(controller.offset, greaterThan(deep - 100));
    expect(hidden(), 0, reason: '往上滑一点，顶栏就应该完整出现');
    expect(tester.getTopLeft(find.text('搜索栏')).dy, greaterThan(statusBar));

    // 再往下滑一点就收起
    await drag(tester, -30);
    expect(hidden(), header);

    // 代码调用 show() 立即显示（如搜索条件变化时）
    headerKey.currentState!.show();
    await tester.pump();
    expect(hidden(), 0);
  });

  testWidgets('收起后状态栏那一条保持背景色，滑上去的顶栏被挡住', (tester) async {
    await pumpList(tester);
    await drag(tester, -1000);
    expect(hidden(), 56 + 48);
    // 状态栏区域被固定的背景挡住，看不到滑上去的顶栏
    final strip = tester
        .widgetList<ColoredBox>(find.byType(ColoredBox))
        .where(
          (box) =>
              box.color ==
              Theme.of(tester.element(find.byType(FloatingHeader)))
                  .colorScheme
                  .surface,
        );
    expect(strip, isNotEmpty);
  });
}
