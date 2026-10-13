import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../services/app_services.dart';
import '../widgets/home_drawer.dart';
import 'downloads_page.dart';
import 'library_pages.dart';
import 'search_results_page.dart';
import 'settings_page.dart';
import 'tag_browser_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// 侧边栏中的栏目（参照 EhViewer：主页、热门、收藏、历史、下载、设置）。
  static const _sections = [
    HomeSection('主页', Icons.home_outlined, Icons.home),
    HomeSection(
      '热门',
      Icons.local_fire_department_outlined,
      Icons.local_fire_department,
    ),
    HomeSection('收藏', Icons.favorite_border, Icons.favorite),
    HomeSection('历史', Icons.history_outlined, Icons.history),
    HomeSection('下载', Icons.download_outlined, Icons.download),
    HomeSection('设置', Icons.settings_outlined, Icons.settings),
  ];

  /// 分隔线下方、打开新页面的项。
  static const _extras = [
    HomeSection('标签目录', Icons.local_offer_outlined, Icons.local_offer),
  ];

  final GlobalKey<ScaffoldState> _scaffold = GlobalKey();
  int _index = 0;
  late final AppLifecycleListener _lifecycle;

  /// 懒加载各个栏目，首次打开时才创建，之后保留状态。
  final List<Widget?> _pages = List.filled(_sections.length, null);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onPause: services.library.save,
      onDetach: services.library.save,
      onExitRequested: () async {
        await services.library.save();
        return AppExitResponse.exit;
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _confirmAge());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _confirmAge() async {
    if (services.settings.ageConfirmed || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: const Text('内容提示'),
        content: const Text(
          '本应用是 hitomi.la 的非官方第三方客户端，浏览的内容可能包含成人内容。\n\n'
          '继续使用即表示你已年满 18 周岁，并且在你所在地区浏览此类内容是合法的。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('退出'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('我已年满 18 岁'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      services.settings.ageConfirmed = true;
    } else {
      await SystemNavigator.pop();
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) exit(0);
    }
  }

  Widget _page(int index) => _pages[index] ??= switch (index) {
    0 => const BrowsePage(),
    1 => const SearchResultsPage(
      isRoot: true,
      sort: SortType.popularityDay,
      hint: '在热门中搜索标题或标签',
    ),
    2 => const FavoritesPage(),
    3 => const HistoryPage(),
    4 => const DownloadsPage(),
    _ => const SettingsPage(),
  };

  void _openExtra(int index) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const TagBrowserPage()));
  }

  @override
  Widget build(BuildContext context) {
    // 不在主页时，返回键先回到主页（与 EhViewer 相同）
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _index = 0);
      },
      child: Scaffold(
        key: _scaffold,
        drawer: HomeDrawer(
          sections: _sections,
          selected: _index,
          onSelected: (index) => setState(() => _index = index),
          extras: _extras,
          onExtra: _openExtra,
        ),
        // 侧边栏平时隐藏，从屏幕左边缘右滑或点顶栏的 ☰ 打开
        drawerEdgeDragWidth: 32,
        body: HomeScope(
          openDrawer: () => _scaffold.currentState?.openDrawer(),
          child: IndexedStack(
            index: _index,
            children: [
              for (var i = 0; i < _sections.length; i++)
                i == _index || _pages[i] != null
                    ? _page(i)
                    : const SizedBox.shrink(),
            ],
          ),
        ),
      ),
    );
  }
}
