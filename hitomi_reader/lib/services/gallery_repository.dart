import 'dart:collection';

import 'package:hitomi_api/hitomi_api.dart';

import '../utils/pool.dart';
import 'download_manager.dart';

/// 画廊信息的内存缓存。已下载的画廊直接从本地读取。
class GalleryRepository {
  GalleryRepository(this._hitomi, this._downloads);

  static const int _capacity = 500;

  final Hitomi _hitomi;
  final DownloadManager _downloads;
  final LinkedHashMap<int, Gallery> _cache = LinkedHashMap();
  final Map<int, Future<Gallery>> _pending = {};
  final Pool _pool = Pool(8);

  Gallery? peek(int id) => _cache[id];

  Future<Gallery> get(int id) {
    final cached = _cache.remove(id);
    if (cached != null) {
      _cache[id] = cached;
      return Future.value(cached);
    }
    // 回调必须是代码块：若返回被移除的 Future，whenComplete 会等待它自身而死锁。
    return _pending[id] ??= _load(id).whenComplete(() {
      _pending.remove(id);
    });
  }

  Future<Gallery> _load(int id) async {
    final local = await _downloads.loadGalleryJson(id);
    final gallery = local != null
        ? Gallery.fromJson(local)
        : await _pool.run(() => _hitomi.galleries.retrieve(id));
    _cache[id] = gallery;
    if (_cache.length > _capacity) _cache.remove(_cache.keys.first);
    return gallery;
  }
}
