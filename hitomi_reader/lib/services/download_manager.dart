import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../utils/files.dart';
import '../utils/pool.dart';
import 'image_loader.dart';

enum DownloadStatus {
  queued('等待中'),
  downloading('下载中'),
  paused('已暂停'),
  completed('已完成'),
  failed('失败');

  const DownloadStatus(this.label);

  final String label;
}

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.title,
    required this.total,
    required this.createdAt,
    this.done = 0,
    this.status = DownloadStatus.queued,
    this.error,
  });

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    var status = DownloadStatus.values.byName(json['status'] as String);
    // 上次退出时仍在下载的任务，重新打开后视为暂停。
    if (status == DownloadStatus.downloading ||
        status == DownloadStatus.queued) {
      status = DownloadStatus.paused;
    }
    return DownloadTask(
      id: json['id'] as int,
      title: json['title'] as String,
      total: json['total'] as int,
      done: json['done'] as int? ?? 0,
      status: status,
      error: json['error'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  final int id;
  final String title;
  final int total;
  final DateTime createdAt;
  int done;
  DownloadStatus status;
  String? error;

  double get progress => total == 0 ? 0 : done / total;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'total': total,
    'done': done,
    'status': status.name,
    'error': error,
    'createdAt': createdAt.toIso8601String(),
  };
}

/// 将画廊原图下载到本地，支持暂停、继续与断点续传（跳过已存在的文件）。
class DownloadManager extends ChangeNotifier {
  DownloadManager._(this.root, this._loader);

  static const int _concurrentPages = 3;

  final Directory root;
  final ImageLoader _loader;
  final Map<int, DownloadTask> _tasks = {};
  DownloadTask? _running;
  Future<void>? _runFuture;

  /// 正在写入 gallery.json、尚不能开始下载的任务。
  final Set<int> _preparing = {};
  DateTime _lastNotify = DateTime(0);
  Future<void> _saving = Future.value();

  static Future<DownloadManager> open(
    Directory root,
    ImageLoader loader,
  ) async {
    final manager = DownloadManager._(root, loader);
    await root.create(recursive: true);
    final file = manager._tasksFile;
    if (await file.exists()) {
      var damaged = false;
      try {
        final list = jsonDecode(await file.readAsString()) as List;
        for (final item in list) {
          try {
            final task = DownloadTask.fromJson(item as Map<String, dynamic>);
            manager._tasks[task.id] = task;
          } catch (error) {
            damaged = true;
            debugPrint('跳过无法解析的下载记录: $error');
          }
        }
      } catch (error) {
        damaged = true;
        debugPrint('读取下载列表失败: $error');
      }
      // 下次保存会覆盖原文件，先备份以免丢失记录。
      if (damaged) await backupFile(file);
    }
    return manager;
  }

  File get _tasksFile => File('${root.path}/tasks.json');

  /// 新任务在前。
  List<DownloadTask> get tasks =>
      _tasks.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  DownloadTask? taskOf(int id) => _tasks[id];

  Directory directoryOf(int id) => Directory('${root.path}/$id');

  String pagePath(int galleryId, int index) =>
      '${root.path}/$galleryId/${(index + 1).toString().padLeft(4, '0')}.webp';

  /// 已下载的页面路径；未开始下载的画廊返回 null。
  String? localPage(int galleryId, int index) =>
      _tasks.containsKey(galleryId) ? pagePath(galleryId, index) : null;

  Future<Map<String, dynamic>?> loadGalleryJson(int id) async {
    if (!_tasks.containsKey(id)) return null;
    final file = File('${directoryOf(id).path}/gallery.json');
    if (!await file.exists()) return null;
    try {
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> enqueue(Gallery gallery) async {
    final existing = _tasks[gallery.id];
    if (existing != null) {
      if (existing.status != DownloadStatus.completed) resume(gallery.id);
      return;
    }
    // 先同步登记，避免连续点击时创建两个任务。
    final task = DownloadTask(
      id: gallery.id,
      title: gallery.title,
      total: gallery.files.length,
      createdAt: DateTime.now(),
    );
    _tasks[gallery.id] = task;
    _preparing.add(gallery.id);
    _changed(force: true);

    final directory = directoryOf(gallery.id);
    try {
      await directory.create(recursive: true);
      await File('${directory.path}/gallery.json')
          .writeAsString(jsonEncode(gallery.toJson()), flush: true);
    } catch (error) {
      task.status = DownloadStatus.failed;
      task.error = '无法写入下载目录：$error';
    } finally {
      _preparing.remove(gallery.id);
    }

    if (!identical(_tasks[gallery.id], task)) {
      // 准备期间任务已被删除。
      await _deleteDirectory(gallery.id);
      return;
    }
    _changed(force: true);
    _pump();
  }

  void pause(int id) {
    final task = _tasks[id];
    if (task == null) return;
    if (task.status == DownloadStatus.queued ||
        task.status == DownloadStatus.downloading) {
      task.status = DownloadStatus.paused;
      _changed(force: true);
    }
  }

  void resume(int id) {
    final task = _tasks[id];
    if (task == null || task.status == DownloadStatus.completed) return;
    if (task.status != DownloadStatus.downloading) {
      task.status = DownloadStatus.queued;
      task.error = null;
      _changed(force: true);
    }
    _pump();
  }

  Future<void> delete(int id) async {
    final task = _tasks.remove(id);
    if (task == null) return;
    // 状态变化后，下载协程不会再开始新的页面，也不会重试。
    task.status = DownloadStatus.paused;
    _changed(force: true);
    if (_preparing.contains(id)) return; // enqueue 结束后会自行清理目录
    if (identical(_running, task)) await _runFuture;
    await _deleteDirectory(id);
  }

  Future<void> _deleteDirectory(int id) async {
    final directory = directoryOf(id);
    for (var attempt = 0; ; attempt++) {
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
        return;
      } on FileSystemException catch (error) {
        // Windows 上文件可能被短暂占用。
        if (attempt >= 2) {
          debugPrint('删除下载目录失败: $error');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  void _pump() {
    if (_running != null) return;
    final next = tasks.reversed
        .where(
          (task) =>
              task.status == DownloadStatus.queued &&
              !_preparing.contains(task.id),
        )
        .firstOrNull;
    if (next == null) return;
    _running = next;
    _runFuture = _run(next).whenComplete(() {
      _running = null;
      _runFuture = null;
      _pump();
    });
  }

  Future<void> _run(DownloadTask task) async {
    task.status = DownloadStatus.downloading;
    _changed(force: true);

    try {
      final json = await loadGalleryJson(task.id);
      if (json == null) throw StateError('缺少 gallery.json');
      final gallery = Gallery.fromJson(json);

      var done = 0;
      final missing = <int>[];
      for (var i = 0; i < gallery.files.length; i++) {
        if (await File(pagePath(task.id, i)).exists()) {
          done++;
        } else {
          missing.add(i);
        }
      }
      task.done = done;
      _changed();

      final pool = Pool(_concurrentPages);
      Object? lastError;
      final failed = <int>[];
      await Future.wait([
        for (final index in missing)
          pool.run(() async {
            if (task.status != DownloadStatus.downloading) return;
            try {
              if (await _downloadPage(task, index, gallery.files[index])) {
                task.done++;
                _changed();
              }
            } catch (error) {
              lastError = error;
              failed.add(index);
            }
          }),
      ]);

      // 图片服务器在并发请求多时会临时返回 503 / 429。稍等一会儿，再逐页重试失败的页面。
      if (failed.isNotEmpty && task.status == DownloadStatus.downloading) {
        await Future<void>.delayed(retryPause);
        for (final index in failed..sort()) {
          if (task.status != DownloadStatus.downloading) break;
          try {
            if (await _downloadPage(task, index, gallery.files[index])) {
              task.done++;
              _changed();
            }
          } catch (error) {
            lastError = error;
          }
        }
      }

      // 暂停或删除时保持当前状态，只在仍处于下载中时给出结果。
      if (task.status == DownloadStatus.downloading) {
        if (task.done >= task.total) {
          task.status = DownloadStatus.completed;
          task.error = null;
        } else {
          task.status = DownloadStatus.failed;
          task.error = '${task.total - task.done} 页下载失败：$lastError';
        }
      }
    } catch (error) {
      if (task.status == DownloadStatus.downloading) {
        task.status = DownloadStatus.failed;
        task.error = '$error';
      }
    }
    _changed(force: true);
  }

  /// 单页重试的基础间隔，之后每次翻倍。
  @visibleForTesting
  static Duration retryDelay = const Duration(seconds: 1);

  /// 第一轮下载结束后，重试失败页面之前的等待时间。
  @visibleForTesting
  static Duration retryPause = const Duration(seconds: 5);

  /// 服务器暂时性的错误（限流、5xx、网络中断、超时）多试几次，其余错误少试。
  static bool _transient(Object error) =>
      error is! HttpStatusException ||
      error.statusCode == 429 ||
      error.statusCode >= 500;

  /// 下载一页并写入文件。任务被暂停或删除时提前结束并返回 false。
  Future<bool> _downloadPage(
    DownloadTask task,
    int index,
    GalleryImage image,
  ) async {
    final galleryId = task.id;
    for (var attempt = 0; ; attempt++) {
      if (task.status != DownloadStatus.downloading) return false;
      try {
        // 若阅读时已缓存过原图则直接复制。
        final cached = _loader.cacheFile(image, ImageKind.full);
        final bytes = await cached.exists()
            ? await cached.readAsBytes()
            : await _loader.download(image, ImageKind.full);
        final file = File(pagePath(galleryId, index));
        if (!await file.parent.exists()) return false; // 目录已被删除
        final temp = File('${file.path}.tmp');
        await temp.writeAsBytes(bytes, flush: true);
        await temp.rename(file.path);
        return true;
      } catch (error) {
        if (attempt + 1 >= (_transient(error) ? 4 : 2)) rethrow;
        // 1、2、4 秒后重试
        await Future<void>.delayed(retryDelay * (1 << attempt));
      }
    }
  }

  void _changed({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastNotify) < const Duration(milliseconds: 250)) {
      return;
    }
    _lastNotify = now;
    notifyListeners();
    _saving = _saving.then((_) => _save());
  }

  Future<void> _save() async {
    try {
      final temp = File('${_tasksFile.path}.tmp');
      await temp.writeAsString(
        jsonEncode([for (final t in _tasks.values) t.toJson()]),
        flush: true,
      );
      await temp.rename(_tasksFile.path);
    } catch (error) {
      debugPrint('保存下载列表失败: $error');
    }
  }
}
