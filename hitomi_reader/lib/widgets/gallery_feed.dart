import 'package:flutter/material.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../navigation.dart';
import '../services/app_services.dart';
import '../services/library_store.dart';
import '../services/settings.dart';
import '../utils/labels.dart';
import 'common.dart';
import 'floating_header.dart';
import 'gallery_card.dart';

/// 搜索结果列表：无限滚动，按页加载画廊信息，并过滤屏蔽标签。
class GalleryFeed extends StatefulWidget {
  const GalleryFeed({
    super.key,
    required this.tags,
    this.title,
    this.orderBy = SortType.dateAdded,
    this.style = ListStyle.list,
    this.origin,
  });

  final List<Tag> tags;
  final String? title;
  final SortType orderBy;
  final ListStyle style;

  /// 用户输入的搜索条件（不含默认语言），详情页可以“加入当前搜索”。
  final SearchQuery? origin;

  @override
  State<GalleryFeed> createState() => GalleryFeedState();
}

class GalleryFeedState extends State<GalleryFeed> {
  static const int _pageSize = 25;

  final ScrollController _scroll = ScrollController();
  late GallerySearch _search;
  final List<Gallery> _items = [];
  int _nextPage = 0;
  int _hidden = 0;
  bool _loading = false;
  bool _done = false;
  Object? _error;

  /// 每次重置后递增，用于丢弃过期请求的结果。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    services.settings.addListener(_onSettingsChanged);
    _blocked = _blockedTags();
    _reset();
  }

  @override
  void didUpdateWidget(GalleryFeed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameTags(oldWidget.tags, widget.tags) ||
        oldWidget.title != widget.title ||
        oldWidget.orderBy != widget.orderBy) {
      _reset();
    }
  }

  @override
  void dispose() {
    services.settings.removeListener(_onSettingsChanged);
    _scroll.dispose();
    super.dispose();
  }

  static bool _sameTags(List<Tag> a, List<Tag> b) =>
      a.length == b.length && a.toSet().containsAll(b);

  late Set<Tag> _blocked;

  Set<Tag> _blockedTags() => {
    for (final raw in services.settings.blockedTags)
      ...services.hitomi.tags.parse(raw).map((tag) => tag.negate(false)),
  };

  void _onSettingsChanged() {
    final blocked = _blockedTags();
    if (blocked.length != _blocked.length || !blocked.containsAll(_blocked)) {
      _blocked = blocked;
      _reset();
    }
  }

  bool _isBlocked(Gallery gallery) =>
      _blocked.isNotEmpty && gallery.allTags.any(_blocked.contains);

  /// 重新开始搜索（下拉刷新也会调用）。
  Future<void> refresh() async {
    _reset();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _reset() {
    _generation++;
    _search = GallerySearch(
      services.hitomi,
      tags: widget.tags,
      title: widget.title,
      orderBy: widget.orderBy,
      pageSize: _pageSize,
    );
    _items.clear();
    _nextPage = 0;
    _hidden = 0;
    _loading = false;
    _done = false;
    _error = null;
    _loadMore();
  }

  void _onScroll() {
    final position = _scroll.position;
    if (position.extentAfter < 1200) _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || _done || _error != null) return;
    final generation = _generation;
    setState(() => _loading = true);

    try {
      final ids = await _search.loadPage(_nextPage);
      if (generation != _generation || !mounted) return;
      if (ids.isEmpty) {
        _done = true;
      } else {
        // 单个画廊失败（如已被删除）时跳过，结果为 Gallery 或异常对象。
        final results = await Future.wait([
          for (final id in ids)
            services.galleries
                .get(id)
                .then<Object>((g) => g, onError: (Object error) => error),
        ]);
        if (generation != _generation || !mounted) return;
        final loaded = results.whereType<Gallery>().toList();
        // 全部失败通常是网络问题：不前进页码，显示错误以便重试。
        if (loaded.isEmpty) throw results.first;
        _nextPage++;
        for (final gallery in loaded) {
          if (_isBlocked(gallery)) {
            _hidden++;
          } else {
            _items.add(gallery);
          }
        }
        final total = _search.total;
        if (ids.length < _pageSize ||
            (total != null && _nextPage * _pageSize >= total)) {
          _done = true;
        }
      }
    } catch (error) {
      if (generation != _generation) return;
      _error = error;
    }

    if (generation != _generation || !mounted) return;
    setState(() => _loading = false);
    // 内容不足一屏时继续加载。整页都被屏蔽时列表为空，此时滚动视图还不存在，
    // 也要继续加载，否则会一直停在加载圈。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _done || _error != null) return;
      if (_items.isEmpty ||
          (_scroll.hasClients && _scroll.position.extentAfter < 1200)) {
        _loadMore();
      }
    });
  }

  void _retry() {
    setState(() => _error = null);
    _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    // 在随滚动收起的顶栏下面时，顶部留出顶栏的空间
    final top = FloatingHeader.topPaddingOf(context);
    if (_items.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: _placeholder(context),
      );
    }

    final theme = Theme.of(context);
    final total = _search.total;
    return RefreshIndicator(
      onRefresh: refresh,
      edgeOffset: top,
      child: Scrollbar(
        controller: _scroll,
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: SizedBox(height: top)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  [
                    if (total != null) '共 ${formatCount(total)} 个结果',
                    if (_hidden > 0) '已隐藏 $_hidden 个',
                    if (_search.ignoredWords.isNotEmpty)
                      '已忽略索引中没有的词：${_search.ignoredWords.join('、')}',
                  ].join(' · '),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            ),
            if (widget.style == ListStyle.list)
              SliverList.builder(
                itemCount: _items.length,
                itemBuilder: (context, index) => _listTile(_items[index]),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.all(12),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 190,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.58,
                  ),
                  itemCount: _items.length,
                  itemBuilder: (context, index) => _gridTile(_items[index]),
                ),
              ),
            SliverToBoxAdapter(child: _footer()),
          ],
        ),
      ),
    );
  }

  /// 还没有结果时：错误、空结果或加载中。
  Widget _placeholder(BuildContext context) {
    if (_error != null) return ErrorView(error: _error!, onRetry: _retry);
    if (_done) {
      final ignored = _search.ignoredWords;
      return EmptyView(
        message: [
          _hidden > 0 ? '没有结果（$_hidden 个因屏蔽标签被隐藏）' : '没有找到相关画廊',
          if (ignored.isNotEmpty) '标题索引中没有这些词：${ignored.join('、')}',
          if (widget.title != null) '刚上传的作品可能还没有进入网站的标题索引',
        ].join('\n'),
        icon: Icons.search_off,
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (!_search.isPaged) ...[
            const SizedBox(height: 16),
            Text(
              widget.title != null
                  ? '正在逐级查询网站的标题索引，通常需要 5～10 秒…'
                  : '复杂查询需要下载完整索引，请稍候…',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ],
      ),
    );
  }

  Widget _listTile(Gallery gallery) => GalleryListTile(
    summary: GallerySummary.fromGallery(gallery),
    tags: [...gallery.series, ...gallery.characters, ...gallery.tags],
    onTap: () => openGallery(context, gallery.id, origin: widget.origin),
    onLongPress: () => showGalleryActions(context, gallery),
  );

  Widget _gridTile(Gallery gallery) => GalleryGridTile(
    summary: GallerySummary.fromGallery(gallery),
    onTap: () => openGallery(context, gallery.id, origin: widget.origin),
    onLongPress: () => showGalleryActions(context, gallery),
  );

  Widget _footer() {
    if (_error != null) {
      return ErrorView(error: _error!, onRetry: _retry, compact: true);
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_done) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            '没有更多了',
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      );
    }
    return const SizedBox(height: 80);
  }
}
