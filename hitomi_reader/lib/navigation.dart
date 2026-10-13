import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hitomi_api/hitomi_api.dart';
import 'package:url_launcher/url_launcher.dart';

import 'pages/gallery_detail_page.dart';
import 'pages/reader_page.dart';
import 'pages/search_page.dart';
import 'pages/search_results_page.dart';
import 'services/app_services.dart';

/// 打开画廊详情。[origin] 为来源搜索条件，详情页可以把标签“加入当前搜索”。
Future<void> openGallery(BuildContext context, int id, {SearchQuery? origin}) =>
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GalleryDetailPage(id: id, origin: origin),
      ),
    );

/// 打开搜索结果页，[query] 使用搜索语法，如 `female:big_breasts`。
Future<void> openSearch(BuildContext context, String query) =>
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            SearchResultsPage(query: services.hitomi.tags.parseQuery(query)),
      ),
    );

/// 先打开搜索条件编辑页（带入 [initial]），确认后再打开结果页。
Future<void> openSearchEditor(BuildContext context, SearchQuery initial) async {
  final query = await Navigator.of(context).push<SearchQuery>(
    MaterialPageRoute(builder: (_) => SearchPage(initial: initial)),
  );
  if (query == null || !context.mounted) return;
  await Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => SearchResultsPage(query: query)));
}

Future<void> openReader(
  BuildContext context,
  Gallery gallery, {
  int page = 0,
}) => Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) => ReaderPage(gallery: gallery, initialPage: page),
  ),
);

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

Future<void> copyText(
  BuildContext context,
  String text, [
  String? label,
]) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showMessage(context, '已复制${label ?? ''}');
}

Future<void> openInBrowser(BuildContext context, String url) async {
  final ok = await launchUrl(
    Uri.parse(url),
    mode: LaunchMode.externalApplication,
  );
  if (!ok && context.mounted) showMessage(context, '无法打开浏览器');
}

/// 长按画廊卡片时的操作菜单。
Future<void> showGalleryActions(BuildContext context, Gallery gallery) {
  final library = services.library;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final favorite = library.isFavorite(gallery.id);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                gallery.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('阅读'),
              onTap: () {
                Navigator.pop(sheetContext);
                final page = library.historyOf(gallery.id)?.page ?? 0;
                openReader(context, gallery, page: page);
              },
            ),
            ListTile(
              leading: Icon(favorite ? Icons.favorite : Icons.favorite_border),
              title: Text(favorite ? '取消收藏' : '收藏'),
              onTap: () {
                Navigator.pop(sheetContext);
                library.setFavorite(gallery, !favorite);
                showMessage(context, favorite ? '已取消收藏' : '已加入收藏');
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('下载'),
              onTap: () {
                Navigator.pop(sheetContext);
                services.downloads.enqueue(gallery);
                showMessage(context, '已加入下载队列');
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('复制链接'),
              onTap: () {
                Navigator.pop(sheetContext);
                copyText(context, gallery.webUrl, '链接');
              },
            ),
          ],
        ),
      );
    },
  );
}
