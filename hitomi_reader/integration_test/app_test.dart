// 端到端冒烟测试：在真实设备/桌面上访问真实服务器，走一遍主要页面并截图。
//
// 运行：flutter test integration_test/app_test.dart -d windows --dart-define=SHOT_DIR=<截图目录>
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hitomi_api/hitomi_api.dart';
import 'package:hitomi_reader/main.dart';
import 'package:hitomi_reader/pages/reader/spreads.dart';
import 'package:hitomi_reader/pages/reader_page.dart';
import 'package:hitomi_reader/services/app_services.dart';
import 'package:hitomi_reader/services/device.dart';
import 'package:hitomi_reader/services/download_manager.dart';
import 'package:hitomi_reader/services/settings.dart';
import 'package:hitomi_reader/widgets/common.dart';
import 'package:hitomi_reader/widgets/floating_header.dart';
import 'package:hitomi_reader/widgets/gallery_card.dart';
import 'package:integration_test/integration_test.dart';

const String _shotDir = String.fromEnvironment('SHOT_DIR');

final GlobalKey _boundary = GlobalKey();

Future<void> _settle(WidgetTester tester, Duration duration) async {
  final end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final end = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(end)) {
      await _shot(tester, 'timeout');
      fail('等待超时：$finder');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
}

/// 设置搜索框内容（光标放在末尾），与用户输入一样会触发联想。
///
/// 桌面集成测试没有注册测试输入法通道，enterText 不总是可靠。
Future<void> _type(WidgetTester tester, String text) async {
  final field = tester.widget<TextField>(find.byType(TextField));
  field.controller!.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );
  await tester.pump();
}

/// 打开侧边栏并选择一项（取代原来的底部导航）。
Future<void> _openSection(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const ValueKey('drawer-menu')));
  await _settle(tester, const Duration(milliseconds: 600));
  await tester.tap(
    find.descendant(
      of: find.byType(NavigationDrawer),
      matching: find.text(label),
    ),
  );
  await _settle(tester, const Duration(milliseconds: 600));
}

Future<void> _shot(WidgetTester tester, String name) async {
  if (_shotDir.isEmpty) return;
  await tester.pump();
  final boundary =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final ui.Image image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('$_shotDir/$name.png');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  debugPrint('截图: ${file.path}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('浏览 → 详情 → 阅读 → 搜索 → 设置', (tester) async {
    await AppServices.init();
    final settings = services.settings
      ..ageConfirmed = true
      ..language = 'all'
      ..listStyle = ListStyle.list
      ..readerMode = ReaderMode.leftToRight
      ..pageLayout = PageLayout.auto
      ..readerGuideShown = false;
    expect(settings.ageConfirmed, isTrue);
    // 确保中文标签库已下载（首次运行时下载约 1.3 MB）
    settings.tagTranslation = true;
    await services.translations.update();
    expect(services.translations.isLoaded, isTrue);

    await tester.pumpWidget(
      RepaintBoundary(key: _boundary, child: const HitomiApp()),
    );

    // 首页列表
    await _waitFor(tester, find.byType(GalleryListTile));
    await _settle(tester, const Duration(seconds: 6));
    await _shot(tester, '01_home');
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.byKey(const ValueKey('drawer-menu')));
    await _settle(tester, const Duration(seconds: 1));
    await _shot(tester, '01b_drawer');
    await tester.binding.handlePopRoute(); // 关闭侧边栏
    await _settle(tester, const Duration(seconds: 1));
    expect(find.byType(NavigationDrawer), findsNothing);

    // 搜索栏和筛选栏随滚动收起，往上滑一点就出现
    final header = tester.state<FloatingHeaderState>(
      find.byType(FloatingHeader).first,
    );
    final list = find.byType(CustomScrollView).first;
    await tester.drag(list, const Offset(0, -1500));
    await _settle(tester, const Duration(seconds: 2));
    expect(header.hiddenExtent, greaterThan(0));
    await _shot(tester, '01c_header_hidden');
    await tester.timedDrag(
      list,
      const Offset(0, 40),
      const Duration(milliseconds: 600),
    );
    await _settle(tester, const Duration(seconds: 1));
    expect(header.hiddenExtent, 0);
    await _shot(tester, '01d_header_back');
    await tester.drag(list, const Offset(0, 5000));
    await _settle(tester, const Duration(seconds: 2));

    // 详情页：选一个页数较少的画廊，便于测试下载
    final tiles = tester
        .widgetList<GalleryListTile>(find.byType(GalleryListTile))
        .toList();
    // 页数较少的画廊，下载步骤更快；但至少 8 页，阅读器的翻页、跳页测试才有意义
    final candidates = tiles.where((tile) => tile.summary.pageCount >= 8);
    final small = (candidates.isEmpty ? tiles : candidates).reduce(
      (a, b) => a.summary.pageCount <= b.summary.pageCount ? a : b,
    );
    final galleryId = small.summary.id;

    // 清理测试数据（包括上次失败残留的），测试失败时也会执行
    Future<void> cleanUp() async {
      await services.downloads.delete(galleryId);
      services.library
        ..removeFavorite(galleryId)
        ..clearHistory();
      await services.library.save();
      settings
        ..clearSearchHistory()
        ..clearRecentTags()
        ..savedSearches = []
        ..readerMode = ReaderMode.leftToRight
        ..pageLayout = PageLayout.auto
        ..verticalWidth = 960
        ..cropBorders = false
        ..readerGuideShown = false
        ..listStyle = ListStyle.list
        ..ageConfirmed = false;
    }

    addTearDown(cleanUp);
    await services.downloads.delete(galleryId);
    services.library.removeFavorite(galleryId);
    await tester.ensureVisible(find.byWidget(small));
    await tester.pump();
    await tester.tap(find.byWidget(small));
    await _waitFor(tester, find.textContaining('阅读'));
    await _settle(tester, const Duration(seconds: 5));
    await _shot(tester, '02_detail');

    await tester.drag(
      find.byType(CustomScrollView).last,
      const Offset(0, -600),
    );
    await _settle(tester, const Duration(seconds: 4));
    await _shot(tester, '03_detail_scrolled');
    await tester.drag(
      find.byType(CustomScrollView).last,
      const Offset(0, 2000),
    );
    await tester.pump();

    // 阅读器：第一次打开显示点击区域说明
    await tester.tap(find.textContaining('阅读').first);
    await _settle(tester, const Duration(seconds: 8));
    final guide = find.byKey(const ValueKey('reader-tap-guide'));
    expect(guide, findsOneWidget);
    await _shot(tester, '04_reader_guide');
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.tapAt(Offset(size.width / 2, size.height / 2));
    await _settle(tester, const Duration(seconds: 1));
    expect(guide, findsNothing);
    await _shot(tester, '04_reader');

    // 桌面窗口是横向的，默认自动双页：封面单独，之后两页一屏（横向的跨页图单独）
    String pageText() =>
        tester.widget<Text>(find.textContaining(' / ').first).data!;
    final files = tester
        .widget<ReaderPage>(find.byType(ReaderPage))
        .gallery
        .files;
    final spreads = ReaderSpreads.build(files, double: true);
    String labelOf(int page) {
      final pages = spreads[spreads.spreadOf(page)];
      final range = pages.length == 2
          ? '${pages[0] + 1}-${pages[1] + 1}'
          : '${pages[0] + 1}';
      return '$range / ${files.length}';
    }

    expect(pageText(), labelOf(0));
    await tester.tapAt(Offset(size.width - 40, size.height / 2));
    await _settle(tester, const Duration(seconds: 5));
    expect(pageText(), labelOf(spreads[1].first));
    await _shot(tester, '05_reader_next');

    // 桌面端滚轮翻页
    final beforeWheel = pageText();
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      mouse.hover(Offset(size.width / 2, size.height / 2)),
    );
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await _settle(tester, const Duration(seconds: 2));
    expect(pageText(), isNot(beforeWheel));

    await tester.tapAt(Offset(size.width / 2, size.height / 2));
    await _settle(tester, const Duration(seconds: 1));
    await _shot(tester, '06_reader_ui');

    // 缩略图跳页
    final thumbnail = min(5, files.length - 1);
    await tester.tap(find.text('缩略图'));
    await _settle(tester, const Duration(seconds: 4));
    await _shot(tester, '06b_reader_thumbnails');
    await tester.tap(find.byKey(ValueKey('thumbnail:$thumbnail')));
    await _settle(tester, const Duration(seconds: 3));
    expect(pageText(), labelOf(thumbnail));

    // 阅读设置面板
    await tester.tapAt(Offset(size.width / 2, size.height / 2));
    await _settle(tester, const Duration(seconds: 1));
    await tester.tap(find.text('阅读设置'));
    await _settle(tester, const Duration(seconds: 1));
    expect(find.text('每屏页数'), findsOneWidget);
    await _shot(tester, '06c_reader_settings');
    await tester.tapAt(Offset(size.width / 2, 20)); // 点遮罩关闭
    await _settle(tester, const Duration(seconds: 1));
    await tester.tapAt(Offset(size.width / 2, size.height / 2)); // 收起菜单
    await _settle(tester, const Duration(seconds: 1));

    // 裁切白边：页面重新加载时检测，显示前就有结果
    settings.cropBorders = true;
    await _settle(tester, const Duration(seconds: 5));
    final visible = spreads[spreads.spreadOf(thumbnail)];
    for (final index in visible) {
      expect(
        services.crops.peek(files[index].hash),
        isNotNull,
        reason: '第 ${index + 1} 页没有检测白边',
      );
    }
    debugPrint(
      '白边检测：${[for (final i in visible) services.crops.peek(files[i].hash)]}',
    );
    await _shot(tester, '06d_reader_cropped');

    // 右键菜单保存图片（保存到临时目录，不写入用户的图片文件夹）
    final saveDirectory = await Directory.systemTemp.createTemp('hitomi_save');
    Device.saveDirectoryOverride = saveDirectory;
    addTearDown(() async {
      Device.saveDirectoryOverride = null;
      await saveDirectory.delete(recursive: true);
    });
    await tester.tap(
      find.byKey(ValueKey('reader-page-${visible.first}')),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await _settle(tester, const Duration(seconds: 1));
    await _shot(tester, '06e_page_menu');
    await tester.tap(find.text('保存图片'));
    await _waitFor(tester, find.textContaining('已保存到'));
    final saved = saveDirectory.listSync();
    expect(saved, hasLength(1));
    expect(
      saved.single.path,
      endsWith(
        'hitomi_${galleryId}_${(visible.first + 1).toString().padLeft(3, '0')}.webp',
      ),
    );
    await _shot(tester, '06f_saved');
    await _settle(tester, const Duration(seconds: 5)); // 等提示消失
    settings.cropBorders = false;
    await tester.tapAt(Offset(size.width / 2, size.height / 2)); // 打开菜单，接着切换模式
    await _settle(tester, const Duration(seconds: 1));

    // 切换到竖向模式
    await tester.tap(find.byIcon(Icons.chrome_reader_mode_outlined));
    await _settle(tester, const Duration(seconds: 1));
    await tester.tap(
      find.widgetWithText(
        CheckedPopupMenuItem<ReaderMode>,
        ReaderMode.vertical.label,
      ),
    );
    await _settle(tester, const Duration(seconds: 6));
    await _shot(tester, '07_reader_vertical');

    // 竖向模式 Ctrl + 滚轮调整图片宽度
    await tester.tapAt(Offset(size.width / 2, size.height / 2)); // 收起菜单
    await _settle(tester, const Duration(seconds: 1));
    final widthBefore = settings.verticalWidth;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    for (var i = 0; i < 3; i++) {
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
      await tester.pump();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _settle(tester, const Duration(seconds: 3));
    expect(settings.verticalWidth, lessThan(widthBefore));
    await _shot(tester, '07b_reader_vertical_narrow');
    await tester.tapAt(Offset(size.width / 2, size.height / 2));
    await _settle(tester, const Duration(seconds: 1));

    await tester.tap(find.byType(BackButton).first);
    await _settle(tester, const Duration(seconds: 1));

    // 收藏与下载
    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.pump();
    expect(services.library.isFavorite(galleryId), isTrue);
    await tester.tap(find.text('下载'));
    // 等到下载完成或失败；失败时报告原因
    final downloadEnd = DateTime.now().add(const Duration(seconds: 240));
    while (true) {
      final status = services.downloads.taskOf(galleryId)?.status;
      if (status == DownloadStatus.completed ||
          status == DownloadStatus.failed ||
          DateTime.now().isAfter(downloadEnd)) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await tester.pump();
    }
    final downloadTask = services.downloads.taskOf(galleryId)!;
    debugPrint(
      '下载：${downloadTask.status.name} ${downloadTask.done}/${downloadTask.total} ${downloadTask.error ?? ''}',
    );
    expect(
      downloadTask.status,
      DownloadStatus.completed,
      reason: downloadTask.error,
    );
    await tester.pump();
    await _shot(tester, '07b_downloaded');

    await tester.tap(find.byType(BackButton).first);
    await _settle(tester, const Duration(seconds: 1));

    // 搜索：中文联想（本地标签库，即时）
    // 打开画廊前列表滚到了画廊所在位置，顶栏已随滚动收起；往上轻滑一下让它出现
    await tester.timedDrag(
      find.byType(CustomScrollView).first,
      const Offset(0, 40),
      const Duration(milliseconds: 600),
    );
    await _settle(tester, const Duration(seconds: 1));
    expect(header.hiddenExtent, 0);
    Finder candidate(String tag) => find.byKey(ValueKey('candidate:$tag'));
    await tester.tap(find.byKey(const ValueKey('search-box')));
    await _settle(tester, const Duration(seconds: 1));
    await _type(tester, '巨乳');
    await _waitFor(
      tester,
      candidate('female:big_breasts'),
      timeout: const Duration(seconds: 10),
    );
    await _shot(tester, '08_search_chinese');

    // 英文联想（本地 + 网站作品数）
    await _type(tester, 'big brea');
    await _waitFor(
      tester,
      find.descendant(
        of: candidate('female:big_breasts'),
        matching: find.textContaining('个作品'),
      ),
      timeout: const Duration(seconds: 30),
    );
    await _shot(tester, '08a_search_suggest');
    await tester.tap(candidate('female:big_breasts'));
    await tester.pump();
    expect(find.text('女性：巨乳'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );

    // 先输入标题词再输入标签名：只替换标签部分，标题保留
    await _type(tester, 'kei-chan 中文');
    await _waitFor(
      tester,
      candidate('language:chinese'),
      timeout: const Duration(seconds: 10),
    );
    await tester.tap(candidate('language:chinese'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'kei-chan ',
    );
    await _type(tester, '');

    await _type(tester, 'netorare');
    await _waitFor(
      tester,
      candidate('female:netorare'),
      timeout: const Duration(seconds: 30),
    );
    await tester.tap(
      find.descendant(
        of: candidate('female:netorare'),
        matching: find.byTooltip('排除'),
      ),
    );
    await tester.pump();
    await _settle(tester, const Duration(milliseconds: 500));
    await _shot(tester, '08b_search_conditions');
    expect(find.textContaining('搜索（3 个标签）'), findsOneWidget);

    await tester.tap(find.textContaining('搜索（3 个标签）'));
    await _waitFor(
      tester,
      find.byType(GalleryListTile),
      timeout: const Duration(seconds: 90),
    );
    await _settle(tester, const Duration(seconds: 5));
    await _shot(tester, '09_search_results');

    // 保存为快速搜索：搜索栏的书签按钮打开右侧抽屉，点 + 保存
    await tester.tap(find.byKey(const ValueKey('quick-search')));
    await _settle(tester, const Duration(seconds: 1));
    await tester.tap(find.byTooltip('保存当前搜索'));
    await tester.pump();
    expect(settings.savedSearches, hasLength(1));
    await _settle(tester, const Duration(milliseconds: 500));
    await _shot(tester, '09b_quick_search');
    await tester.binding.handlePopRoute(); // 关闭抽屉
    await _settle(tester, const Duration(seconds: 1));

    // 网格视图
    await tester.tap(find.byIcon(Icons.grid_view));
    await _waitFor(tester, find.byType(GalleryGridTile));
    await _settle(tester, const Duration(seconds: 5));
    await _shot(tester, '10_grid');
    settings.listStyle = ListStyle.list;
    await tester.pump();

    // 粘贴完整标题搜索（取本月热门，确保已进入网站的标题索引）
    final popular = await services.hitomi.galleries.listPage(
      tags: const [Tag(TagType.language, 'chinese')],
      orderBy: SortType.popularityMonth,
      page: 0,
      pageSize: 1,
    );
    final target = await services.galleries.get(popular.ids.first);
    await tester.tap(find.byKey(const ValueKey('search-box')));
    await _settle(tester, const Duration(seconds: 1));
    await tester.tap(find.text('清空'));
    await tester.pump();
    expect(find.text('快速搜索'), findsOneWidget);
    await _shot(tester, '10a_search_idle');
    // 粘贴链接可直接打开
    await _type(
      tester,
      'https://hitomi.la/doujinshi/some-title-${target.id}.html',
    );
    await tester.pump();
    expect(find.text('打开画廊 #${target.id}'), findsOneWidget);

    await _type(tester, target.title);
    await tester.pump();
    await _shot(tester, '10b_title_typing');
    // 输入停顿时会提前查询标题，稍等片刻再提交
    await _settle(tester, const Duration(seconds: 3));
    final submitWatch = Stopwatch()..start();
    // 桌面集成测试里无法模拟输入法的回车动作，直接调用回车对应的回调。
    tester.widget<TextField>(find.byType(TextField)).onSubmitted!(target.title);
    await _waitFor(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is GalleryListTile && widget.summary.id == target.id,
      ),
      timeout: const Duration(seconds: 90),
    );
    debugPrint('标题搜索提交后 ${submitWatch.elapsedMilliseconds}ms 出现结果');
    await _settle(tester, const Duration(seconds: 3));
    await _shot(tester, '11_title_search');

    // 高级语法（标签 + 排除），仍然支持
    await tester.tap(find.byKey(const ValueKey('search-box')));
    await _settle(tester, const Duration(seconds: 1));
    await _type(tester, 'series:blue_archive -male:yaoi');
    await tester.pump();
    await tester.tap(find.textContaining('搜索（2 个标签）'));
    await _waitFor(
      tester,
      find.byType(GalleryListTile),
      timeout: const Duration(seconds: 90),
    );
    await _settle(tester, const Duration(seconds: 4));
    await _shot(tester, '11b_complex_search');

    // 从当前搜索打开画廊，长按标签“加入当前搜索”
    await tester.tap(find.byType(GalleryListTile).first);
    await _waitFor(tester, find.textContaining('阅读'));
    await _settle(tester, const Duration(seconds: 2));
    await _shot(tester, '11c_detail_chinese_tags');
    await tester.longPress(find.byType(TagChip).last);
    await _settle(tester, const Duration(seconds: 1));
    expect(find.text('加入当前搜索'), findsOneWidget);
    await _shot(tester, '11d_tag_sheet');
    await tester.tap(find.text('加入当前搜索'));
    await _waitFor(
      tester,
      find.byType(GalleryListTile),
      timeout: const Duration(seconds: 90),
    );
    await _settle(tester, const Duration(seconds: 3));
    await _shot(tester, '11e_added_to_search');
    await tester.tap(find.byType(BackButton).first);
    await _settle(tester, const Duration(seconds: 1));
    await tester.tap(find.byType(BackButton).first);
    await _settle(tester, const Duration(seconds: 1));

    // 收藏页：与普通搜索相同的条件编辑，按标签包含 / 排除
    final favorite = services.galleries.peek(galleryId)!;
    final favoriteTag = favorite.allTags.firstWhere(
      (tag) => tag.type != TagType.type && tag.type != TagType.language,
      orElse: () => favorite.allTags.first,
    );
    Finder favoriteTile() => find.byWidgetPredicate(
      (widget) => widget is GalleryListTile && widget.summary.id == galleryId,
    );
    await _openSection(tester, '收藏');
    await _settle(tester, const Duration(seconds: 2));
    expect(favoriteTile(), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('favorites-search-box')));
    await _settle(tester, const Duration(seconds: 1));
    await _type(tester, '$favoriteTag');
    await _settle(tester, const Duration(seconds: 2));
    await _shot(tester, '12a_favorites_search');
    tester.widget<TextField>(find.byType(TextField)).onSubmitted!('');
    await _settle(tester, const Duration(seconds: 1));
    expect(favoriteTile(), findsOneWidget);
    await _shot(tester, '12b_favorites_filtered');
    await tester.tap(find.byType(InputChip).first); // 切换为排除
    await tester.pump();
    expect(favoriteTile(), findsNothing);
    await tester.tap(find.widgetWithText(ActionChip, '清空'));
    await tester.pump();

    // 设置页
    await _openSection(tester, '设置');
    await _settle(tester, const Duration(seconds: 2));
    await _shot(tester, '12_settings');

    // 屏蔽标签：中文联想（只看联想，不改动屏蔽列表）
    final blockedBefore = settings.blockedTags;
    await tester.tap(find.text('屏蔽标签'));
    await _settle(tester, const Duration(seconds: 1));
    await _type(tester, '眼镜');
    await _waitFor(
      tester,
      find.byKey(const ValueKey('block-candidate:female:glasses')),
      timeout: const Duration(seconds: 10),
    );
    await _shot(tester, '12c_blocked_suggest');
    await tester.tap(find.byType(BackButton).first);
    await _settle(tester, const Duration(seconds: 1));
    expect(settings.blockedTags, blockedBefore);

    // 历史页
    await _openSection(tester, '历史');
    await _settle(tester, const Duration(seconds: 3));
    await _shot(tester, '13_history');

    // 下载页，并从本地文件打开阅读
    await _openSection(tester, '下载');
    await _settle(tester, const Duration(seconds: 2));
    await _shot(tester, '13b_downloads');
    final task = services.downloads.taskOf(galleryId)!;
    expect(task.done, task.total);
    expect(
      File(services.downloads.pagePath(galleryId, 0)).existsSync(),
      isTrue,
    );
    await tester.tap(find.text(task.title).first);
    await _settle(tester, const Duration(seconds: 3));
    await _shot(tester, '13c_offline_reader');
    await tester.binding.handlePopRoute();
    await _settle(tester, const Duration(seconds: 1));

    // 标签目录
    await _openSection(tester, '标签目录');
    await _waitFor(
      tester,
      find.byType(ListTile),
      timeout: const Duration(seconds: 60),
    );
    await _settle(tester, const Duration(seconds: 1));
    await _shot(tester, '14_tags');
  });
}
