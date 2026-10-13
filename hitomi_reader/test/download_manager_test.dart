import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hitomi_api/hitomi_api.dart';
import 'package:hitomi_reader/services/download_manager.dart';
import 'package:hitomi_reader/services/image_loader.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _ggJs = "var o = 0; switch (g) { case 1: o = 1; break; } b: '123/'";

Future<void> _until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('等待超时');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory root;
  late DownloadManager manager;

  final gallery = Gallery.fromJson({
    'id': '42',
    'title': 'test',
    'type': 'manga',
    'files': [
      for (var i = 0; i < 12; i++)
        {'hash': 'abcdef$i$i$i', 'name': '$i.webp', 'width': 10, 'height': 10},
    ],
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hitomi_download_test');
    final client = MockClient((request) async {
      if (request.url.path == '/gg.js') return http.Response(_ggJs, 200);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return http.Response.bytes(List.filled(16, 7), 200);
    });
    final hitomi = Hitomi(client: client);
    final loader = ImageLoader(hitomi, client, Directory('${root.path}/cache'));
    manager = await DownloadManager.open(Directory('${root.path}/dl'), loader);
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await root.delete(recursive: true);
  });

  test('连续点击下载只会创建一个任务', () async {
    await Future.wait([manager.enqueue(gallery), manager.enqueue(gallery)]);
    expect(manager.tasks, hasLength(1));
    await _until(() => manager.taskOf(42)?.status == DownloadStatus.completed);
    expect(manager.taskOf(42)!.done, 12);
    expect(File(manager.pagePath(42, 11)).readAsBytesSync(), hasLength(16));
  });

  test('下载过程中删除会等待写入结束并清理目录', () async {
    await manager.enqueue(gallery);
    await _until(() => (manager.taskOf(42)?.done ?? 0) > 0);
    await manager.delete(42);
    expect(manager.taskOf(42), isNull);
    expect(manager.directoryOf(42).existsSync(), isFalse);

    // 删除后可以重新下载
    await manager.enqueue(gallery);
    await _until(() => manager.taskOf(42)?.status == DownloadStatus.completed);
  });

  test('暂停后保持暂停状态，继续后完成', () async {
    await manager.enqueue(gallery);
    await _until(() => (manager.taskOf(42)?.done ?? 0) > 0);
    manager.pause(42);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final task = manager.taskOf(42)!;
    expect(task.status, DownloadStatus.paused);
    expect(task.done, lessThan(12));
    manager.resume(42);
    await _until(() => task.status == DownloadStatus.completed);
    expect(task.done, 12);
  });

  test('服务器临时返回 503 时多次重试，最终下载完成', () async {
    DownloadManager.retryDelay = const Duration(milliseconds: 10);
    DownloadManager.retryPause = const Duration(milliseconds: 10);
    addTearDown(() {
      DownloadManager.retryDelay = const Duration(seconds: 1);
      DownloadManager.retryPause = const Duration(seconds: 5);
    });
    var failures = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/gg.js') return http.Response(_ggJs, 200);
      // 第 6 页连续 6 次 503：超过第一轮的 4 次，在第二轮重试中成功
      if (request.url.path.contains('abcdef555') && failures < 6) {
        failures++;
        return http.Response('', 503);
      }
      return http.Response.bytes(List.filled(16, 7), 200);
    });
    final loader = ImageLoader(
      Hitomi(client: client),
      client,
      Directory('${root.path}/cache503'),
    );
    final manager503 = await DownloadManager.open(
      Directory('${root.path}/dl503'),
      loader,
    );
    await manager503.enqueue(gallery);
    await _until(
      () =>
          manager503.taskOf(42)?.status == DownloadStatus.completed ||
          manager503.taskOf(42)?.status == DownloadStatus.failed,
    );
    expect(manager503.taskOf(42)!.status, DownloadStatus.completed);
    expect(manager503.taskOf(42)!.done, 12);
    expect(failures, 6);
  });
}
