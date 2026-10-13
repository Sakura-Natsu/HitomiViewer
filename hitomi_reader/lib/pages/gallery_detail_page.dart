import 'package:flutter/material.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../navigation.dart';
import '../services/app_services.dart';
import '../services/download_manager.dart';
import '../services/image_loader.dart';
import '../services/library_store.dart';
import '../utils/labels.dart';
import '../widgets/common.dart';
import '../widgets/gallery_card.dart';
import '../widgets/hitomi_image.dart';
import 'search_page.dart';

class GalleryDetailPage extends StatefulWidget {
  const GalleryDetailPage({super.key, required this.id, this.origin});

  final int id;

  /// 从哪个搜索进入，用于把标签“加入当前搜索”。
  final SearchQuery? origin;

  @override
  State<GalleryDetailPage> createState() => _GalleryDetailPageState();
}

class _GalleryDetailPageState extends State<GalleryDetailPage> {
  late Future<Gallery> _future = services.galleries.get(widget.id);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Gallery>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return _GalleryDetailView(
            gallery: snapshot.data!,
            origin: widget.origin,
          );
        }
        return Scaffold(
          appBar: AppBar(title: Text('#${widget.id}')),
          body: snapshot.hasError
              ? ErrorView(
                  error: snapshot.error!,
                  onRetry: () => setState(() {
                    _future = services.galleries.get(widget.id);
                  }),
                )
              : const Center(child: CircularProgressIndicator()),
        );
      },
    );
  }
}

class _GalleryDetailView extends StatelessWidget {
  const _GalleryDetailView({required this.gallery, this.origin});

  final Gallery gallery;
  final SearchQuery? origin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sections = <(String, List<Tag>)>[
      ('作者', gallery.artists),
      ('社团', gallery.groups),
      ('原作', gallery.series),
      ('角色', gallery.characters),
      ('标签', gallery.tags),
    ];

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            title: Text(
              gallery.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              ListenableBuilder(
                listenable: services.library,
                builder: (context, _) {
                  final favorite = services.library.isFavorite(gallery.id);
                  return IconButton(
                    tooltip: favorite ? '取消收藏' : '收藏',
                    icon: Icon(
                      favorite ? Icons.favorite : Icons.favorite_border,
                      color: favorite ? Colors.pink : null,
                    ),
                    onPressed: () =>
                        services.library.setFavorite(gallery, !favorite),
                  );
                },
              ),
              PopupMenuButton<String>(
                onSelected: (value) => switch (value) {
                  'link' => copyText(context, gallery.webUrl, '链接'),
                  'browser' => openInBrowser(context, gallery.webUrl),
                  'id' => copyText(context, '${gallery.id}', ' ID'),
                  'title' => copyText(context, gallery.title, '标题'),
                  _ => null,
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'link', child: Text('复制链接')),
                  PopupMenuItem(value: 'browser', child: Text('在浏览器中打开')),
                  PopupMenuItem(value: 'title', child: Text('复制标题')),
                  PopupMenuItem(value: 'id', child: Text('复制 ID')),
                ],
              ),
            ],
          ),
          SliverToBoxAdapter(child: _header(context)),
          SliverToBoxAdapter(child: _actions(context)),
          if (gallery.video != null)
            SliverToBoxAdapter(
              child: ListTile(
                leading: const Icon(Icons.movie_outlined),
                title: const Text('这是一个视频画廊'),
                subtitle: const Text('应用内暂不支持播放，可复制视频地址'),
                trailing: TextButton(
                  onPressed: () =>
                      copyText(context, gallery.video!.url, '视频地址'),
                  child: const Text('复制'),
                ),
              ),
            ),
          for (final (label, tags) in sections)
            if (tags.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 44,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            label,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final tag in tags)
                              TagChip(
                                tag: tag,
                                onTap: () => openSearch(context, '$tag'),
                                onLongPress: () =>
                                    _showTagActions(context, tag),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          if (gallery.translations.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 44,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '其他语言',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final translation in gallery.translations)
                            ActionChip(
                              visualDensity: VisualDensity.compact,
                              label: Text(
                                languageLabel(translation.language.name),
                              ),
                              onPressed: () =>
                                  openGallery(context, translation.id),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(
                '预览（${gallery.files.length} 页）',
                style: theme.textTheme.titleMedium,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 120,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 0.7,
              ),
              itemCount: gallery.files.length,
              itemBuilder: (context, index) =>
                  _PageThumbnail(gallery: gallery, index: index),
            ),
          ),
          if (gallery.relatedIds.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                child: Text('相关推荐', style: theme.textTheme.titleMedium),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 250,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: gallery.relatedIds.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, index) =>
                      _RelatedCard(id: gallery.relatedIds[index]),
                ),
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final cover = gallery.cover;
    final infoStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 130,
              height: 184,
              child: cover == null
                  ? ColoredBox(color: theme.colorScheme.surfaceContainerHighest)
                  : GestureDetector(
                      onTap: () => openReader(context, gallery),
                      child: HitomiImage(
                        image: cover,
                        kind: ImageKind.thumbnailBig,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  gallery.title,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    GestureDetector(
                      onTap: () => openSearch(context, 'type:${gallery.type}'),
                      child: TypeBadge(gallery.type),
                    ),
                    if (gallery.language != null)
                      GestureDetector(
                        onTap: () =>
                            openSearch(context, '${gallery.language!.toTag()}'),
                        child: Text(
                          languageLabel(gallery.language!.name),
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: tagTypeColor(TagType.language),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${gallery.files.length} 页 · #${gallery.id}',
                  style: infoStyle,
                ),
                const SizedBox(height: 2),
                Text('上传：${formatDate(gallery.addedDate)}', style: infoStyle),
                if (gallery.publishedDate != null)
                  Text(
                    '发布：${formatDate(gallery.publishedDate)}',
                    style: infoStyle,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: ListenableBuilder(
        listenable: Listenable.merge([services.library, services.downloads]),
        builder: (context, _) {
          final history = services.library.historyOf(gallery.id);
          final task = services.downloads.taskOf(gallery.id);
          final resumePage = history != null && history.page > 0
              ? history.page
              : null;
          return Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: gallery.files.isEmpty
                      ? null
                      : () =>
                            openReader(context, gallery, page: resumePage ?? 0),
                  icon: const Icon(Icons.menu_book),
                  label: Text(
                    resumePage != null
                        ? '继续阅读（${resumePage + 1}/${gallery.files.length}）'
                        : '开始阅读',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _DownloadButton(gallery: gallery, task: task),
            ],
          );
        },
      ),
    );
  }

  void _showTagActions(BuildContext context, Tag tag) {
    final info = services.tagLabels.info(tag);
    final origin = this.origin;
    final inOrigin =
        origin?.tags.any((t) => t.type == tag.type && t.name == tag.name) ??
        false;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.8,
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tagFullName(sheetContext, tag),
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      SelectableText(
                        '$tag',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      if (info != null && info.intro.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          info.intro,
                          style: theme.textTheme.bodySmall?.copyWith(
                            height: 1.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.search),
                  title: const Text('搜索此标签'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    openSearch(context, '$tag');
                  },
                ),
                if (origin != null && !origin.isEmpty && !inOrigin)
                  ListTile(
                    leading: const Icon(Icons.add_circle_outline),
                    title: const Text('加入当前搜索'),
                    subtitle: Text(
                      '在「${describeQuery(sheetContext, origin)}」的基础上再筛选',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      openSearch(
                        context,
                        '${origin.copyWith(tags: [...origin.tags, tag])}',
                      );
                    },
                  ),
                if (origin != null && !origin.isEmpty && !inOrigin)
                  ListTile(
                    leading: const Icon(Icons.remove_circle_outline),
                    title: const Text('从当前搜索中排除'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      openSearch(
                        context,
                        '${origin.copyWith(tags: [...origin.tags, tag.negate(true)])}',
                      );
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.filter_alt_outlined),
                  title: const Text('组合筛选…'),
                  subtitle: const Text('以此标签为条件，再添加其他标签或标题'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    openSearchEditor(context, SearchQuery(tags: [tag]));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.block),
                  title: const Text('屏蔽此标签'),
                  subtitle: const Text('含有此标签的画廊将不再出现在列表中'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    final blocked = services.settings.blockedTags;
                    if (!blocked.contains('$tag')) {
                      services.settings.blockedTags = [...blocked, '$tag'];
                    }
                    showMessage(context, '已屏蔽 ${tagName(context, tag)}');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.copy),
                  title: const Text('复制'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    copyText(context, '$tag');
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.gallery, required this.task});

  final Gallery gallery;
  final DownloadTask? task;

  @override
  Widget build(BuildContext context) {
    final task = this.task;
    if (task == null) {
      return OutlinedButton.icon(
        onPressed: () {
          services.downloads.enqueue(gallery);
          showMessage(context, '已加入下载队列');
        },
        icon: const Icon(Icons.download_outlined),
        label: const Text('下载'),
      );
    }
    final (icon, label, action) = switch (task.status) {
      DownloadStatus.completed => (Icons.download_done, '已下载', null),
      DownloadStatus.downloading => (
        Icons.pause,
        '${(task.progress * 100).toStringAsFixed(0)}%',
        () => services.downloads.pause(gallery.id),
      ),
      DownloadStatus.queued => (
        Icons.schedule,
        '等待中',
        () => services.downloads.pause(gallery.id),
      ),
      DownloadStatus.paused || DownloadStatus.failed => (
        Icons.play_arrow,
        task.status.label,
        () => services.downloads.resume(gallery.id),
      ),
    };
    return OutlinedButton.icon(
      onPressed: action,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

class _PageThumbnail extends StatelessWidget {
  const _PageThumbnail({required this.gallery, required this.index});

  final Gallery gallery;
  final int index;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => openReader(context, gallery, page: index),
      borderRadius: BorderRadius.circular(6),
      child: Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: HitomiImage(
                image: gallery.files[index],
                kind: ImageKind.thumbnailSmall,
                fit: BoxFit.cover,
                width: double.infinity,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text('${index + 1}', style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}

class _RelatedCard extends StatelessWidget {
  const _RelatedCard({required this.id});

  final int id;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      child: FutureBuilder<Gallery>(
        initialData: services.galleries.peek(id),
        future: services.galleries.get(id),
        builder: (context, snapshot) {
          final gallery = snapshot.data;
          if (gallery == null) {
            return Card(
              margin: EdgeInsets.zero,
              child: Center(
                child: snapshot.hasError
                    ? Icon(
                        Icons.error_outline,
                        color: Theme.of(context).colorScheme.outline,
                      )
                    : const CircularProgressIndicator(),
              ),
            );
          }
          return GalleryGridTile(
            summary: GallerySummary.fromGallery(gallery),
            onTap: () => openGallery(context, id),
            onLongPress: () => showGalleryActions(context, gallery),
          );
        },
      ),
    );
  }
}
