import 'package:flutter/material.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../utils/labels.dart';

class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.error,
    this.onRetry,
    this.compact = false,
  });

  final Object error;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!compact)
              Icon(
                Icons.cloud_off_outlined,
                size: 48,
                color: theme.colorScheme.outline,
              ),
            if (!compact) const SizedBox(height: 12),
            Text(
              describeError(error),
              textAlign: TextAlign.center,
              maxLines: compact ? 3 : 8,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
  });

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: colors.outline),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// 画廊类型角标。
class TypeBadge extends StatelessWidget {
  const TypeBadge(this.type, {super.key, this.dense = false});

  final String type;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 4 : 6,
        vertical: dense ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: galleryTypeColor(type),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        galleryTypeLabel(type),
        style: TextStyle(
          color: Colors.white,
          fontSize: dense ? 10 : 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class TagChip extends StatelessWidget {
  const TagChip({
    super.key,
    required this.tag,
    this.onTap,
    this.onLongPress,
    this.showType = false,
    this.count,
    this.dense = false,
  });

  final Tag tag;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool showType;
  final int? count;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = tagTypeColor(tag.type);
    final theme = Theme.of(context);
    final symbol = switch (tag.type) {
      TagType.female => '♀ ',
      TagType.male => '♂ ',
      _ => '',
    };
    return Material(
      color: color.withValues(alpha: tag.isNegative ? 0.08 : 0.14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(dense ? 6 : 8),
        side: BorderSide(color: color.withValues(alpha: 0.5)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(dense ? 6 : 8),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? 6 : 10,
            vertical: dense ? 2 : 5,
          ),
          child: Text.rich(
            TextSpan(
              children: [
                if (tag.isNegative)
                  TextSpan(
                    text: '排除 ',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                if (showType)
                  TextSpan(
                    text: '${tagTypeLabel(tag.type)}: ',
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                TextSpan(text: '$symbol${tagName(context, tag)}'),
                if (count != null)
                  TextSpan(
                    text: '  ${formatCount(count!)}',
                    style: TextStyle(color: theme.colorScheme.outline),
                  ),
              ],
            ),
            style: TextStyle(
              fontSize: dense ? 11 : 13,
              decoration: tag.isNegative ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
      ),
    );
  }
}
