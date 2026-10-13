import 'package:flutter/material.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../navigation.dart';
import '../services/app_services.dart';
import '../services/library_store.dart';
import '../services/settings.dart';
import '../utils/labels.dart';
import '../widgets/common.dart';
import '../widgets/floating_header.dart';
import '../widgets/gallery_card.dart';
import '../widgets/home_drawer.dart';
import 'search_page.dart';
import 'search_results_page.dart';

/// 收藏列表。搜索与普通搜索相同：可以按标题查找，叠加包含 / 排除的标签。
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  SearchQuery _query = const SearchQuery();
  final GlobalKey<FloatingHeaderState> _header = GlobalKey();

  /// 修改筛选条件：顶栏完全显示出来。
  void _update(VoidCallback change) {
    setState(change);
    _header.currentState?.show();
  }

  @override
  void initState() {
    super.initState();
    // 旧版本保存的收藏没有标签信息，后台补全后才能按标签筛选
    final library = services.library;
    if (library.favoritesMissingTags > 0) {
      library.fillFavoriteDetails(services.galleries.get);
    }
  }

  Future<void> _editQuery() async {
    final result = await Navigator.of(context).push<SearchQuery>(
      MaterialPageRoute(
        builder: (_) =>
            SearchPage(initial: _query, scope: SearchScope.favorites),
      ),
    );
    if (result != null && mounted) _update(() => _query = result);
  }

  void _removeTag(Tag tag) => _update(() {
    _query = _query.copyWith(tags: [..._query.tags]..remove(tag));
  });

  void _toggleTag(Tag tag) => _update(() {
    _query = _query.copyWith(
      tags: [for (final t in _query.tags) t == tag ? t.negate() : t],
    );
  });

  @override
  Widget build(BuildContext context) {
    final style = services.settings.listStyle;
    final menu = drawerMenuButton(context);
    final theme = Theme.of(context);
    return Scaffold(
      // 搜索栏和筛选栏随滚动收起：往下滑隐藏，任意位置往上滑就出现
      body: FloatingHeader(
        key: _header,
        header: AppBar(
          primary: false,
          backgroundColor: theme.colorScheme.surface,
          notificationPredicate: (_) => false,
          automaticallyImplyLeading: menu == null,
          titleSpacing: menu == null ? 0 : 12,
          title: SearchBox(
            key: const ValueKey('favorites-search-box'),
            text: _query.isEmpty ? '' : describeQuery(context, _query),
            hint: '在收藏中搜索标题或标签',
            onTap: _editQuery,
            leading: menu,
            actions: [
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
          bottom: _query.isEmpty ? null : _conditions(),
        ),
        body: ListenableBuilder(
          listenable: Listenable.merge([services.library, services.settings]),
          builder: (context, _) {
            final top = FloatingHeader.topPaddingOf(context);
            final library = services.library;
            final all = library.favorites;
            if (all.isEmpty) {
              return Padding(
                padding: EdgeInsets.only(top: top),
                child: const EmptyView(
                  message: '还没有收藏\n在画廊详情页点击 ♡ 即可收藏',
                  icon: Icons.favorite_border,
                ),
              );
            }
            final entries = [
              for (final entry in all)
                if (entry.gallery.matches(_query)) entry,
            ];
            final missing = library.favoritesMissingTags;
            // 提示和数量跟着列表一起滚动
            final header = [
              if (_query.tags.isNotEmpty && missing > 0)
                _FillingNotice(
                  missing: missing,
                  running: library.isFillingDetails,
                ),
              if (!_query.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '共 ${entries.length} 本（全部 ${all.length} 本）',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ];
            if (entries.isEmpty) {
              return Padding(
                padding: EdgeInsets.only(top: top),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ...header,
                    const Expanded(child: EmptyView(message: '没有符合条件的收藏')),
                  ],
                ),
              );
            }
            return _SummaryList(
              topPadding: top,
              header: header,
              items: [
                for (final entry in entries)
                  (entry.gallery, '收藏于 ${formatDateTime(entry.addedAt)}'),
              ],
              onRemove: (id) {
                services.library.removeFavorite(id);
                showMessage(context, '已取消收藏');
              },
            );
          },
        ),
      ),
    );
  }

  /// 当前条件：标题、包含 / 排除的标签，与搜索结果页相同。
  PreferredSizeWidget _conditions() {
    return PreferredSize(
      preferredSize: const Size.fromHeight(48),
      child: SizedBox(
        height: 48,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          children: [
            if (_query.title != null) ...[
              InputChip(
                avatar: const Icon(Icons.title, size: 18),
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(_query.title!, overflow: TextOverflow.ellipsis),
                ),
                tooltip: '点按修改',
                visualDensity: VisualDensity.compact,
                onPressed: _editQuery,
                onDeleted: () => _update(() => _query = _query.withoutTitle()),
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
            const SizedBox(width: 8),
            ActionChip(
              avatar: const Icon(Icons.clear, size: 18),
              label: const Text('清空'),
              visualDensity: VisualDensity.compact,
              onPressed: () => _update(() => _query = const SearchQuery()),
            ),
          ],
        ),
      ),
    );
  }
}

/// 旧收藏还没有标签信息时的提示。
class _FillingNotice extends StatelessWidget {
  const _FillingNotice({required this.missing, required this.running});

  final int missing;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            if (running) ...[
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                running
                    ? '正在补全 $missing 本旧收藏的标签信息，完成后会出现在筛选结果中'
                    : '$missing 本收藏暂时无法获取标签信息，按标签筛选时不会出现',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空阅读历史？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) services.library.clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: drawerMenuButton(context),
        title: const Text('历史'),
        actions: [
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => _confirmClear(context),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([services.library, services.settings]),
        builder: (context, _) {
          final entries = services.library.history;
          if (entries.isEmpty) {
            return const EmptyView(message: '还没有阅读记录', icon: Icons.history);
          }
          return _SummaryList(
            items: [
              for (final entry in entries)
                (
                  entry.gallery,
                  '读到 ${entry.page + 1}/${entry.gallery.pageCount} 页 · ${formatDateTime(entry.readAt)}',
                ),
            ],
            onRemove: services.library.removeHistory,
          );
        },
      ),
    );
  }
}

/// 收藏与历史共用的列表，左滑删除。
class _SummaryList extends StatelessWidget {
  const _SummaryList({
    required this.items,
    required this.onRemove,
    this.header = const [],
    this.topPadding = 0,
  });

  final List<(GallerySummary, String)> items;
  final ValueChanged<int> onRemove;

  /// 列表前面跟着一起滚动的内容（如筛选结果数量）。
  final List<Widget> header;

  /// 在随滚动收起的顶栏下面时，顶部留出的空间。
  final double topPadding;

  @override
  Widget build(BuildContext context) {
    final grid = services.settings.listStyle == ListStyle.grid;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: SizedBox(height: topPadding)),
        for (final widget in header) SliverToBoxAdapter(child: widget),
        if (grid)
          SliverPadding(
            padding: const EdgeInsets.all(12),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 190,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.58,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final (summary, _) = items[index];
                return GalleryGridTile(
                  summary: summary,
                  onTap: () => openGallery(context, summary.id),
                  onLongPress: () => _confirmRemove(context, summary),
                );
              },
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.only(top: 4, bottom: 16),
            sliver: SliverList.builder(
              itemCount: items.length,
              itemBuilder: (context, index) {
                final (summary, subtitle) = items[index];
                return Dismissible(
                  key: ValueKey(summary.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: const Icon(Icons.delete_outline),
                  ),
                  onDismissed: (_) => onRemove(summary.id),
                  child: GalleryListTile(
                    summary: summary,
                    subtitle: subtitle,
                    onTap: () => openGallery(context, summary.id),
                    onLongPress: () => _confirmRemove(context, summary),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    GallerySummary summary,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除？'),
        content: Text(
          summary.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed == true) onRemove(summary.id);
  }
}
