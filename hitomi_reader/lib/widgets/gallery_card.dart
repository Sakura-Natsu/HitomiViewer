import 'package:flutter/material.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../services/image_loader.dart';
import '../services/library_store.dart';
import '../utils/labels.dart';
import 'common.dart';
import 'hitomi_image.dart';

/// 列表样式的画廊卡片。
class GalleryListTile extends StatelessWidget {
  const GalleryListTile({
    super.key,
    required this.summary,
    this.tags = const [],
    this.subtitle,
    this.onTap,
    this.onLongPress,
    this.trailing,
  });

  final GallerySummary summary;
  final List<Tag> tags;

  /// 额外的说明行，如阅读进度。
  final String? subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  static const double height = 156;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cover = summary.cover;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: SizedBox(
          height: height - 10,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 104,
                child: cover == null
                    ? ColoredBox(
                        color: theme.colorScheme.surfaceContainerHighest,
                      )
                    : HitomiImage(image: cover, kind: ImageKind.thumbnailBig),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        summary.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      if (summary.artists.isNotEmpty)
                        Text(
                          summary.artists.join(', '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: tagTypeColor(TagType.artist),
                          ),
                        ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          TypeBadge(summary.type, dense: true),
                          if (summary.language != null)
                            Text(
                              languageLabel(summary.language!),
                              style: theme.textTheme.labelSmall,
                            ),
                          Text(
                            '${summary.pageCount}P',
                            style: theme.textTheme.labelSmall,
                          ),
                          Text(
                            formatDate(summary.date),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle!,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                      const Spacer(),
                      if (tags.isNotEmpty)
                        ClipRect(
                          child: SizedBox(
                            height: 20,
                            child: Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              children: [
                                for (final tag in tags.take(12))
                                  TagChip(tag: tag, dense: true),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

/// 网格样式的画廊卡片。
class GalleryGridTile extends StatelessWidget {
  const GalleryGridTile({
    super.key,
    required this.summary,
    this.onTap,
    this.onLongPress,
  });

  final GallerySummary summary;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cover = summary.cover;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (cover != null)
                    HitomiImage(image: cover, kind: ImageKind.thumbnailBig)
                  else
                    ColoredBox(
                      color: theme.colorScheme.surfaceContainerHighest,
                    ),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: TypeBadge(summary.type, dense: true),
                  ),
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        [
                          if (summary.language != null)
                            languageLabel(summary.language!),
                          '${summary.pageCount}P',
                        ].join(' · '),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Text(
                summary.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
