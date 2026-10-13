import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hitomi_api/hitomi_api.dart';
import 'package:hitomi_reader/pages/home_page.dart';
import 'package:hitomi_reader/pages/tag_browser_page.dart';
import 'package:hitomi_reader/services/app_services.dart';
import 'package:hitomi_reader/services/http_client.dart';
import 'package:hitomi_reader/services/settings.dart';
import 'package:hitomi_reader/services/tag_labels.dart';
import 'package:hitomi_reader/utils/labels.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory directory;

  Future<void> pumpHome(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('home_page_test');
      final settings = AppSettings(await SharedPreferences.getInstance());
      await AppServices.create(
        settings: settings,
        http: ProxyHttpClient(const ProxyConfig(mode: ProxyMode.direct)),
        client: MockClient((_) async => http.Response('', 404)),
        supportDirectory: Directory('${directory.path}/support'),
        cacheDirectory: Directory('${directory.path}/cache'),
        downloadDirectory: Directory('${directory.path}/downloads'),
      );
      settings.ageConfirmed = true;
    });
    await tester.pumpWidget(
      TagLabelScope(
        labels: services.tagLabels,
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pump();
  }

  Future<void> tearDownHome(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(() async {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // 记录可能还在写入
      }
    });
  }

  Future<void> animate(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('drawer-menu')));
    await animate(tester);
  }

  Finder drawerItem(String label) => find.descendant(
    of: find.byType(NavigationDrawer),
    matching: find.text(label),
  );

  testWidgets('侧边栏取代底部导航：平时隐藏，☰ 打开，切换栏目，返回键回到主页', (tester) async {
    await pumpHome(tester);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationDrawer), findsNothing);
    expect(find.byKey(const ValueKey('search-box')), findsOneWidget);

    await openDrawer(tester);
    expect(find.text('HitomiViewer'), findsOneWidget);
    for (final label in ['主页', '热门', '收藏', '历史', '下载', '设置', '标签目录']) {
      expect(drawerItem(label), findsOneWidget, reason: label);
    }

    await tester.tap(drawerItem('收藏'));
    await animate(tester);
    expect(find.byType(NavigationDrawer), findsNothing, reason: '选择后侧边栏关闭');
    expect(find.byKey(const ValueKey('favorites-search-box')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-box')), findsNothing);

    // 每个栏目都能打开侧边栏
    await openDrawer(tester);
    await tester.tap(drawerItem('设置'));
    await animate(tester);
    expect(find.text('标签翻译'), findsWidgets);

    // 返回键先回到主页
    await tester.binding.handlePopRoute();
    await animate(tester);
    expect(find.byKey(const ValueKey('search-box')), findsOneWidget);
    expect(find.text('标签翻译'), findsNothing);
    await tearDownHome(tester);
  });

  testWidgets('从左边缘右滑打开侧边栏；标签目录作为新页面打开', (tester) async {
    await pumpHome(tester);
    await tester.dragFrom(const Offset(4, 400), const Offset(300, 0));
    await animate(tester);
    expect(find.byType(NavigationDrawer), findsOneWidget);

    await tester.tap(drawerItem('标签目录'));
    await animate(tester);
    expect(find.byType(TagBrowserPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await animate(tester);
    expect(find.byType(TagBrowserPage), findsNothing);
    expect(find.byKey(const ValueKey('search-box')), findsOneWidget);
    await tearDownHome(tester);
  });

  testWidgets('热门栏目按今日人气排序；搜索栏的书签按钮打开快速搜索', (tester) async {
    await pumpHome(tester);
    await openDrawer(tester);
    await tester.tap(drawerItem('热门'));
    await animate(tester);
    expect(find.text(sortLabel(SortType.popularityDay)), findsOneWidget);
    expect(find.text('在热门中搜索标题或标签'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('quick-search')));
    await animate(tester);
    expect(find.text('快速搜索'), findsOneWidget);
    expect(find.text('还没有快速搜索'), findsOneWidget);
    await tearDownHome(tester);
  });
}
