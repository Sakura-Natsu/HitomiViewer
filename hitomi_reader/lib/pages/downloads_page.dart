import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../navigation.dart';
import '../services/app_services.dart';
import '../services/download_manager.dart';
import '../widgets/common.dart';
import '../widgets/home_drawer.dart';

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  Future<void> _confirmDelete(BuildContext context, DownloadTask task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除下载？'),
        content: Text('将删除「${task.title}」的本地文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await services.downloads.delete(task.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: drawerMenuButton(context),
        title: const Text('下载'),
        actions: [
          IconButton(
            tooltip: '下载目录',
            icon: const Icon(Icons.folder_outlined),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('下载目录'),
                content: SelectableText(services.downloads.root.path),
                actions: [
                  TextButton(
                    onPressed: () =>
                        copyText(context, services.downloads.root.path, '路径'),
                    child: const Text('复制'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: services.downloads,
        builder: (context, _) {
          final tasks = services.downloads.tasks;
          if (tasks.isEmpty) {
            return const EmptyView(
              message: '没有下载任务\n在画廊详情页点击“下载”即可离线保存',
              icon: Icons.download_outlined,
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: tasks.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 88),
            itemBuilder: (context, index) => _TaskTile(
              task: tasks[index],
              onDelete: () => _confirmDelete(context, tasks[index]),
            ),
          );
        },
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task, required this.onDelete});

  final DownloadTask task;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final downloads = services.downloads;
    final firstPage = downloads.pagePath(task.id, 0);
    final (IconData icon, VoidCallback? action) = switch (task.status) {
      DownloadStatus.downloading || DownloadStatus.queued => (
        Icons.pause_circle_outline,
        () => downloads.pause(task.id),
      ),
      DownloadStatus.paused || DownloadStatus.failed => (
        Icons.play_circle_outline,
        () => downloads.resume(task.id),
      ),
      DownloadStatus.completed => (Icons.check_circle_outline, null),
    };
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 56,
          height: 78,
          child: task.done > 0 && File(firstPage).existsSync()
              ? Image(
                  image: ResizeImage(
                    FileImage(File(firstPage)),
                    width: 160,
                    policy: ResizeImagePolicy.fit,
                  ),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => ColoredBox(
                    color: theme.colorScheme.surfaceContainerHighest,
                  ),
                )
              : ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
        ),
      ),
      title: Text(task.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 6),
          if (task.status != DownloadStatus.completed)
            LinearProgressIndicator(value: task.progress),
          const SizedBox(height: 4),
          Text(
            '${task.status.label} · ${task.done}/${task.total}'
            '${task.error != null ? '\n${task.error}' : ''}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: task.status == DownloadStatus.failed
                  ? theme.colorScheme.error
                  : null,
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (action != null) IconButton(icon: Icon(icon), onPressed: action),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      ),
      onTap: () async {
        if (task.status == DownloadStatus.completed) {
          final gallery = await services.galleries
              .get(task.id)
              .then<Gallery?>((g) => g, onError: (_) => null);
          if (gallery != null && context.mounted) {
            openReader(
              context,
              gallery,
              page: services.library.historyOf(task.id)?.page ?? 0,
            );
            return;
          }
        }
        if (context.mounted) openGallery(context, task.id);
      },
    );
  }
}
