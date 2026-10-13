import 'package:flutter/material.dart';

/// 首页侧边栏的入口（参照 EhViewer）：各栏目页面通过它打开侧边栏。
class HomeScope extends InheritedWidget {
  const HomeScope({super.key, required this.openDrawer, required super.child});

  final VoidCallback openDrawer;

  static HomeScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<HomeScope>();

  @override
  bool updateShouldNotify(HomeScope oldWidget) => false;
}

/// 栏目页顶栏左侧的菜单按钮；页面不在首页里（被单独打开）时返回 null。
Widget? drawerMenuButton(BuildContext context) {
  final scope = HomeScope.maybeOf(context);
  if (scope == null) return null;
  return IconButton(
    key: const ValueKey('drawer-menu'),
    tooltip: '菜单',
    icon: const Icon(Icons.menu),
    onPressed: scope.openDrawer,
  );
}

/// 侧边栏中的一项。
class HomeSection {
  const HomeSection(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// 侧边栏：顶部是应用图标和名称，下面是各个栏目。
class HomeDrawer extends StatelessWidget {
  const HomeDrawer({
    super.key,
    required this.sections,
    required this.selected,
    required this.onSelected,
    this.extras = const [],
    this.onExtra,
  });

  final List<HomeSection> sections;
  final int selected;
  final ValueChanged<int> onSelected;

  /// 分隔线下方、打开新页面的项（如标签目录），不会成为选中项。
  final List<HomeSection> extras;
  final ValueChanged<int>? onExtra;

  @override
  Widget build(BuildContext context) {
    return NavigationDrawer(
      selectedIndex: selected,
      onDestinationSelected: (index) {
        Navigator.pop(context); // 关闭侧边栏
        if (index < sections.length) {
          onSelected(index);
        } else {
          onExtra?.call(index - sections.length);
        }
      },
      children: [
        const _DrawerHeader(),
        for (final section in sections)
          NavigationDrawerDestination(
            icon: Icon(section.icon),
            selectedIcon: Icon(section.selectedIcon),
            label: Text(section.label),
          ),
        if (extras.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 28, vertical: 8),
            child: Divider(height: 1),
          ),
        for (final extra in extras)
          NavigationDrawerDestination(
            icon: Icon(extra.icon),
            selectedIcon: Icon(extra.selectedIcon),
            label: Text(extra.label),
          ),
      ],
    );
  }
}

class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
      // 与应用图标的粉色背景一致
      color: dark ? const Color(0xFF4A2F37) : const Color(0xFFFCD8DF),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.asset('assets/icon.png', width: 64, height: 64),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'HitomiViewer',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: dark ? Colors.white : const Color(0xFF5A3440),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'hitomi.la 非官方客户端',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: dark ? Colors.white70 : const Color(0xFF8A5A66),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
