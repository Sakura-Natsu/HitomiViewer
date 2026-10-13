import 'gallery_manager.dart';
import 'hitomi.dart';
import 'models/tag.dart';

/// 按页加载搜索结果。
///
/// 简单查询（见 [GalleryManager.isPageable]）使用 Range 请求逐页获取；
/// 复杂查询会在第一次加载时取得完整结果，之后在本地分页。
class GallerySearch {
  GallerySearch(
    this._hitomi, {
    this.tags = const [],
    this.title,
    this.orderBy = SortType.dateAdded,
    this.pageSize = 25,
  });

  final Hitomi _hitomi;
  final List<Tag> tags;
  final String? title;
  final SortType orderBy;
  final int pageSize;

  int? _total;
  Future<GalleryListResult>? _all;
  List<String> _ignoredWords = const [];

  bool get isPaged =>
      GalleryManager.isPageable(tags: tags, title: title, orderBy: orderBy);

  /// 结果总数，在第一页加载完成后可用。
  int? get total => _total;

  int? get pageCount => _total == null ? null : (_total! / pageSize).ceil();

  /// 标题中因索引里不存在而被忽略的词（标题搜索采用宽松匹配）。
  List<String> get ignoredWords => _ignoredWords;

  Future<List<int>> loadPage(int page) async {
    if (isPaged) {
      final result = await _hitomi.galleries.listPage(
        tags: tags,
        orderBy: orderBy,
        page: page,
        pageSize: pageSize,
      );
      _total = result.total ?? _total;
      return result.ids;
    }

    final future = _all ??= _hitomi.galleries.search(
      tags: tags,
      title: title,
      orderBy: orderBy,
      lenientTitle: true,
    );
    final List<int> all;
    try {
      final result = await future;
      all = result.ids;
      _ignoredWords = result.ignoredWords;
    } catch (_) {
      // 失败后允许重试。
      if (identical(_all, future)) _all = null;
      rethrow;
    }
    _total = all.length;
    final start = page * pageSize;
    if (start >= all.length) return const [];
    final end = start + pageSize;
    return all.sublist(start, end > all.length ? all.length : end);
  }
}
