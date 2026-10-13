import 'package:flutter_test/flutter_test.dart';
import 'package:hitomi_api/hitomi_api.dart';
import 'package:hitomi_reader/services/http_client.dart';
import 'package:hitomi_reader/services/library_store.dart';
import 'package:hitomi_reader/utils/labels.dart';
import 'package:hitomi_reader/utils/pool.dart';

void main() {
  test('parses Windows proxy server settings', () {
    expect(parseWindowsProxyServer('127.0.0.1:7890'), '127.0.0.1:7890');
    expect(
      parseWindowsProxyServer('http=127.0.0.1:7890;https=127.0.0.1:7891'),
      '127.0.0.1:7891',
    );
    expect(parseWindowsProxyServer('socks=127.0.0.1:1080'), isNull);
    expect(
      parseWindowsProxyServer('http://proxy.local:8080'),
      'proxy.local:8080',
    );
    expect(parseWindowsProxyServer(''), isNull);
  });

  test('gallery summary round-trips through json', () {
    final gallery = Gallery.fromJson({
      'id': '42',
      'title': 'Title',
      'type': 'manga',
      'language': 'chinese',
      'language_localname': '中文',
      'artists': [
        {'artist': 'someone'},
      ],
      'files': [
        {'hash': 'abc123', 'name': '1.webp', 'width': 100, 'height': 140},
      ],
      'date': '2024-01-02 03:04:05-05',
    });
    final summary = GallerySummary.fromGallery(gallery);
    final restored = GallerySummary.fromJson(summary.toJson());
    expect(restored.id, 42);
    expect(restored.artists, ['someone']);
    expect(restored.coverHash, 'abc123');
    expect(restored.cover!.hasThumbnail, isTrue);
    expect(restored.pageCount, 1);
    expect(restored.date, gallery.addedDate);
  });

  test('formats numbers and sizes', () {
    expect(formatCount(1234567), '1,234,567');
    expect(formatCount(12), '12');
    expect(formatBytes(1536), '1.5 KB');
    expect(languageOptions.first, 'all');
    expect(languageOptions.toSet().length, languageOptions.length);
  });

  test('pool limits concurrency and supports lifo order', () async {
    final pool = Pool(2, lifo: true);
    var running = 0;
    var peak = 0;
    final order = <int>[];
    Future<void> task(int id) => pool.run(() async {
      running++;
      peak = running > peak ? running : peak;
      order.add(id);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      running--;
    });
    await Future.wait([for (var i = 0; i < 5; i++) task(i)]);
    expect(peak, 2);
    expect(order.take(2), [0, 1]);
    // 等待中的 2、3、4 按后进先出执行
    expect(order.skip(2), [4, 3, 2]);
  });
}
