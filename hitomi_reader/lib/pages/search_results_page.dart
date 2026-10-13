import 'package:flutter/material.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../navigation.dart';
import '../services/app_services.dart';
import '../services/settings.dart';
import '../utils/labels.dart';
import '../widgets/common.dart';
import '../widgets/floating_header.dart';
import '../widgets/gallery_feed.dart';
import '../widgets/home_drawer.dart';
import 'search_page.dart';

/// 浏览/搜索页面。首页标签页与从标签点进来的搜索结果共用。
class SearchResultsPage extends StatefulWidget {
  const SearchResultsPage({
    super.key,
    this.query = const SearchQuery(),
    this.isRoot = false,
    this.sort,
    this.hint = '搜索标题，或添加标签筛选',
  });

  final SearchQuery query;

  /// 首页栏目（主页、热门）：没有返回按钮，搜索框左侧是侧边栏菜单，
  /// 并跟随设置中的默认语言变化。
  final bool isRoot;

  /// 固定的初始排序（如热门栏目按今日人气），为 null 时使用设置中的默认排序并跟随变化。
  final SortType? sort;

  /// 没有搜索条件时搜索框里的提示。
  final String hint;

  @override
  State<SearchResultsPage> createState() => _SearchResultsPageState();
}

class _SearchResultsPageState extends State<SearchResultsPage> {
  final GlobalKey<GalleryFeedState> _feedKey = GlobalKey();
  final GlobalKey<ScaffoldState> _scaffold = GlobalKey();
  final GlobalKey<FloatingHeaderState> _header = GlobalKey();
  late SearchQuery _query = widget.query;
  late String _language = services.settings.language;
  late SortType _sort = widget.sort ?? services.settings.defaultSort;

  @override
  void initState() {
    super.initState();
    services.settings.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    services.settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  String _lastDefaultLanguage = services.settings.language;
  SortType _lastDefaultSort = services.settings.defaultSort;

  void _onSettingsChanged() {
    final settings = services.settings;
    if (!widget.isRoot) {
      setState(() {}); // 列表样式可能变化
      return;
    }
    setState(() {
      if (settings.language != _lastDefaultLanguage) {
        _language = settings.language;
      }
      if (settings.defaultSort != _lastDefaultSort && widget.sort == null) {
        _sort = settings.defaultSort;
      }
      _lastDefaultLanguage = settings.language;
      _lastDefaultSort = settings.defaultSort;
    });
  }

  /// 搜索条件中没有指定语言时使用当前语言筛选。
  bool get _queryHasLanguage =>
      _query.tags.any((tag) => tag.type == TagType.language && !tag.isNegative);

  List<Tag> get _effectiveTags => [
    ..._query.tags,
    if (!_queryHasLanguage && _language != 'all')
      Tag(TagType.language, _language),
  ];

  /// 修改搜索条件：列表会重新加载，顶栏完全显示出来。
  void _update(VoidCallback change) {
    setState(change);
    _header.currentState?.show();
  }

  Future<void> _editQuery() async {
    final result = await Navigator.of(context).push<SearchQuery>(
      MaterialPageRoute(builder: (_) => SearchPage(initial: _query)),
    );
    if (result != null) _update(() => _query = result);
  }

  void _removeTag(Tag tag) => _update(() {
    _query = _query.copyWith(tags: [..._query.tags]..remove(tag));
  });

  /// 在包含与排除之间切换。
  void _toggleTag(Tag tag) => _update(() {
    _query = _query.copyWith(
      tags: [for (final t in _query.tags) t == tag ? t.negate() : t],
    );
  });

  Future<void> _pickLanguage() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          children: [
            for (final name in languageOptions)
              ListTile(
                title: Text(languageOptionLabel(name)),
                trailing: name == _language ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, name),
              ),
          ],
        ),
      ),
    );
    if (selected != null) _update(() => _language = selected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = services.settings.listStyle;
    return Scaffold(
      key: _scaffold,
      // 右侧的快速搜索（与 EhViewer 相同，点搜索栏的书签按钮或从右边缘左滑打开）
      endDrawer: _QuickSearchDrawer(
        query: _query,
        onSelected: (query) => _update(() => _query = query),
      ),
      // 搜索栏和筛选栏随滚动收起：往下滑隐藏，任意位置往上滑就出现（与 EhViewer 相同）
      body: FloatingHeader(
        key: _header,
        header: AppBar(
          primary: false,
          backgroundColor: theme.colorScheme.surface,
          // 内容在顶栏下面滚动，不要随滚动变色（状态栏那一条是固定的背景色）
          notificationPredicate: (_) => false,
          automaticallyImplyLeading: !widget.isRoot,
          // 快速搜索的按钮在搜索栏里，不要自动添加右侧抽屉按钮
          automaticallyImplyActions: false,
          titleSpacing: widget.isRoot ? 12 : 0,
          title: SearchBox(
            key: const ValueKey('search-box'),
            text: _query.isEmpty ? '' : describeQuery(context, _query),
            hint: widget.hint,
            onTap: _editQuery,
            leading: widget.isRoot ? drawerMenuButton(context) : null,
            actions: [
              IconButton(
                key: const ValueKey('quick-search'),
                tooltip: '快速搜索',
                icon: const Icon(Icons.bookmarks_outlined),
                onPressed: () => _scaffold.currentState?.openEndDrawer(),
              ),
              IconButton(
                tooltip: style == ListStyle.list ? '网格视图' : '列表视图',
                icon: Icon(
                  style == ListStyle.list ? Icons.grid_view : Icons.view_list,
                ),
                onPressed: () => services.settings.listStyle =
                    style == ListStyle.list ? ListStyle.grid : ListStyle.list,
              ),
            ],
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                children: [
                  PopupMenuButton<SortType>(
                    initialValue: _sort,
                    onSelected: (value) => _update(() => _sort = value),
                    itemBuilder: (context) => [
                      for (final sort in SortType.values)
                        PopupMenuItem(
                          value: sort,
                          child: Text(sortLabel(sort)),
                        ),
                    ],
                    child: Chip(
                      avatar: const Icon(Icons.sort, size: 18),
                      label: Text(sortLabel(_sort)),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (!_queryHasLanguage) ...[
                    ActionChip(
                      avatar: const Icon(Icons.translate, size: 18),
                      label: Text(languageOptionLabel(_language)),
                      visualDensity: VisualDensity.compact,
                      onPressed: _pickLanguage,
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (_query.title != null) ...[
                    InputChip(
                      avatar: const Icon(Icons.title, size: 18),
                      label: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 220),
                        child: Text(
                          _query.title!,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      tooltip: '点按修改',
                      visualDensity: VisualDensity.compact,
                      onPressed: _editQuery,
                      onDeleted: () =>
                          _update(() => _query = _query.withoutTitle()),
                    ),
                    const SizedBox(width: 8),
                  ],
                  for (final tag in _query.tags) ...[
                    ConditionChip(
                      tag: tag,
                      dense: true,
                      onToggle: () => _toggleTag(tag),
                      onDelete: () => _removeTag(tag),
                    ),
                    const SizedBox(width: 8),
                  ],
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: const Text('添加条件'),
                    visualDensity: VisualDensity.compact,
                    onPressed: _editQuery,
                  ),
                ],
              ),
            ),
          ),
        ),
        body: GalleryFeed(
          key: _feedKey,
          tags: _effectiveTags,
          title: _query.title,
          origin: _query,
          orderBy: _sort,
          style: style,
        ),
      ),
      floatingActionButton:
          theme.platform == TargetPlatform.android ||
              theme.platform == TargetPlatform.iOS
          ? null
          : FloatingActionButton.small(
              tooltip: '刷新',
              onPressed: () => _feedKey.currentState?.refresh(),
              child: const Icon(Icons.refresh),
            ),
    );
  }
}

/// 顶栏中的胶囊形搜索框，点按文字打开搜索条件编辑页。
///
/// 可以在左侧放菜单按钮、右侧放操作按钮（与 EhViewer 的搜索栏相同）。
class SearchBox extends StatelessWidget {
  const SearchBox({
    super.key,
    required this.text,
    required this.onTap,
    this.hint = '搜索标题，或添加标签筛选',
    this.leading,
    this.actions = const [],
  });

  final String text;
  final VoidCallback onTap;
  final String hint;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            ?leading,
            Expanded(
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: leading == null ? 14 : 4,
                    right: 8,
                  ),
                  child: Row(
                    children: [
                      if (leading == null) ...[
                        Icon(
                          Icons.search,
                          size: 20,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          text.isEmpty ? hint : text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            color: text.isEmpty
                                ? colors.onSurfaceVariant
                                : colors.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// 右侧抽屉：快速搜索（保存的搜索）。
class _QuickSearchDrawer extends StatelessWidget {
  const _QuickSearchDrawer({required this.query, required this.onSelected});

  final SearchQuery query;
  final ValueChanged<SearchQuery> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      child: SafeArea(
        child: ListenableBuilder(
          listenable: services.settings,
          builder: (context, _) {
            final settings = services.settings;
            final saved = settings.savedSearches;
            final current = '$query';
            final canSave = !query.isEmpty && !settings.isSavedSearch(current);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('快速搜索', style: theme.textTheme.titleLarge),
                      ),
                      IconButton(
                        tooltip: '保存当前搜索',
                        icon: const Icon(Icons.add),
                        onPressed: canSave
                            ? () {
                                settings.saveSearch(
                                  savedSearchFor(context, query),
                                );
                                showMessage(context, '已保存当前搜索');
                              }
                            : null,
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    query.isEmpty
                        ? '搜索后点 + 可以把当前条件保存在这里'
                        : canSave
                        ? '点 + 保存当前搜索'
                        : '当前搜索已保存',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: saved.isEmpty
                      ? const EmptyView(
                          message: '还没有快速搜索',
                          icon: Icons.bookmarks_outlined,
                        )
                      : ListView(
                          children: [
                            for (final search in saved)
                              ListTile(
                                leading: const Icon(Icons.bookmark_outline),
                                title: Text(
                                  search.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                selected: search.query == current,
                                onTap: () {
                                  Navigator.pop(context); // 关闭抽屉
                                  onSelected(
                                    services.hitomi.tags.parseQuery(
                                      search.query,
                                    ),
                                  );
                                },
                                trailing: IconButton(
                                  tooltip: '删除',
                                  icon: const Icon(Icons.close),
                                  onPressed: () =>
                                      settings.removeSavedSearch(search.query),
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 首页使用的浏览页。
class BrowsePage extends StatelessWidget {
  const BrowsePage({super.key});

  @override
  Widget build(BuildContext context) => const SearchResultsPage(isRoot: true);
}
