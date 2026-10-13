import 'dart:typed_data';

import 'cached_value.dart';
import 'constants.dart';
import 'error.dart';
import 'hitomi.dart';

class IndexData {
  const IndexData(this.offset, this.length);

  final int offset;
  final int length;

  @override
  String toString() => 'IndexData($offset, $length)';
}

class IndexNode {
  const IndexNode(this.keys, this.datas, this.subnodeAddresses);

  final List<Uint8List> keys;
  final List<IndexData> datas;

  /// 17 个子节点地址，全部为 0 时为叶子节点。
  final List<int> subnodeAddresses;

  /// 对应 search.js 的 decode_node。
  static IndexNode decode(ByteData view) {
    final keys = <Uint8List>[];
    final datas = <IndexData>[];
    final subnodeAddresses = <int>[];

    var offset = 0;
    final keyCount = view.getInt32(offset);
    offset += 4;

    for (var i = 0; i < keyCount; i++) {
      final keySize = view.getInt32(offset);
      offset += 4;
      if (keySize < 1 || keySize > 31) {
        throw HitomiException(
          HitomiErrorCode.unexpectedResponseBody,
          'Index key size must be between 1 and 31, got $keySize',
        );
      }
      keys.add(Uint8List.sublistView(view, offset, offset + keySize));
      offset += keySize;
    }

    final dataCount = view.getInt32(offset);
    offset += 4;

    for (var i = 0; i < dataCount; i++) {
      datas.add(IndexData(view.getUint64(offset), view.getInt32(offset + 8)));
      offset += 12;
    }

    for (var i = 0; i < 17; i++) {
      subnodeAddresses.add(view.getUint64(offset));
      offset += 8;
    }

    return IndexNode(keys, datas, subnodeAddresses);
  }
}

/// 对应 search.js 的 compare_arraybuffers。
int compareKeys(Uint8List a, Uint8List b) {
  final length = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    if (a[i] < b[i]) return -1;
    if (a[i] > b[i]) return 1;
  }
  return 0;
}

/// 读取远程 B 树索引（galleriesindex / languagesindex）。
///
/// 索引文件通过 HTTP Range 请求按节点读取，不需要整体下载。
class IndexProvider {
  IndexProvider(this._hitomi, this.field, Duration maxAge)
    : version = CachedValue(
        () async => (await _hitomi.request(
          resourceDomain,
          '/${field}index/version',
        )).text.trim(),
        maxAge,
      );

  final Hitomi _hitomi;

  /// `galleries` 或 `languages`。
  final String field;

  final CachedValue<String> version;

  String indexPath(String version) => '/${field}index/$field.$version.index';

  String dataPath(String version) => '/${field}index/$field.$version.data';

  /// 节点缓存。索引文件按版本号命名、内容不变，多词搜索时根节点和上层节点会被反复访问。
  final Map<String, Future<IndexNode?>> _nodes = {};

  /// 约 4 MB；足够容纳预取的上层节点和多次搜索经过的节点。
  static const int _maxCachedNodes = 4096;

  /// 一次 multi-range 请求最多包含的范围数（实测 200 个仍正常）。
  static const int _rangesPerRequest = 200;

  Future<IndexNode?> getNodeAtAddress(int address, String version) {
    final key = '$version@$address';
    final cached = _nodes.remove(key);
    if (cached != null) return _nodes[key] = cached;
    if (_nodes.length >= _maxCachedNodes) _nodes.remove(_nodes.keys.first);
    final future = _fetchNode(address, version);
    // 失败的请求不缓存，下次重新获取。
    future.catchError((Object _) {
      _nodes.remove(key);
      return null;
    });
    return _nodes[key] = future;
  }

  /// 预取根节点以下 [levels] 层的全部节点，每层只需一到两次 multi-range 请求。
  ///
  /// galleriesindex 深约 7 层，第二层约 200 个节点（约 100 KB）。
  /// 预取后每次查找可以少走 [levels] + 1 次网络往返。
  Future<void> prefetch(String version, {int levels = 2}) async {
    var addresses = [0];
    for (var level = 0; level <= levels && addresses.isNotEmpty; level++) {
      final missing = [
        for (final address in addresses)
          if (!_nodes.containsKey('$version@$address')) address,
      ];
      await Future.wait([
        for (var i = 0; i < missing.length; i += _rangesPerRequest)
          _prefetchChunk(
            version,
            missing.sublist(
              i,
              i + _rangesPerRequest > missing.length
                  ? missing.length
                  : i + _rangesPerRequest,
            ),
          ),
      ]);
      if (level == levels) break;
      final nodes = await Future.wait(
        addresses.map((address) => getNodeAtAddress(address, version)),
      );
      addresses = [
        for (final node in nodes)
          if (node != null)
            for (final child in node.subnodeAddresses)
              if (child != 0) child,
      ];
    }
  }

  Future<void> _prefetchChunk(String version, List<int> addresses) async {
    final parts = await _hitomi.requestRanges(
      resourceDomain,
      indexPath(version),
      [
        for (final address in addresses)
          (address, address + maxIndexNodeSize - 1),
      ],
    );
    for (final address in addresses) {
      final bytes = parts[address];
      if (bytes == null) continue; // 缺失的节点之后按需单独获取
      final key = '$version@$address';
      _nodes.remove(key);
      if (_nodes.length >= _maxCachedNodes) _nodes.remove(_nodes.keys.first);
      _nodes[key] = Future.value(
        bytes.isEmpty ? null : IndexNode.decode(ByteData.sublistView(bytes)),
      );
    }
  }

  Future<IndexNode?> _fetchNode(int address, String version) async {
    final response = await _hitomi.request(
      resourceDomain,
      indexPath(version),
      range: '$address-${address + maxIndexNodeSize - 1}',
    );
    if (response.bytes.isEmpty) return null;
    return IndexNode.decode(response.view);
  }

  /// 在单个节点中查找：命中时返回数据，否则返回应继续查找的子节点地址（0 表示不存在）。
  static (IndexData?, int) _step(Uint8List key, IndexNode node) {
    if (node.keys.isEmpty) return (null, 0);

    var compareResult = -1;
    var index = 0;
    while (index < node.keys.length) {
      compareResult = compareKeys(key, node.keys[index]);
      if (compareResult != 1) break;
      index++;
    }

    if (compareResult == 0) return (node.datas[index], 0);
    return (null, node.subnodeAddresses[index]);
  }

  /// 对应 search.js 的 B_search。
  Future<IndexData?> binarySearch(
    Uint8List key,
    IndexNode node,
    String version,
  ) async {
    final (data, address) = _step(key, node);
    if (data != null || address == 0) return data;
    final subnode = await getNodeAtAddress(address, version);
    if (subnode == null) return null;
    return binarySearch(key, subnode, version);
  }

  /// 同时查找多个键。逐层前进，同一层需要的节点合并为一次 multi-range 请求，
  /// 因此总耗时约等于树的层数次往返，并且只占用一条连接。
  Future<List<IndexData?>> searchMany(
    List<Uint8List> keys,
    String version,
  ) async {
    final results = List<IndexData?>.filled(keys.length, null);
    final root = await getNodeAtAddress(0, version);
    if (root == null) throw HitomiException.emptyRootNode();

    var pending = <int, IndexNode>{
      for (var i = 0; i < keys.length; i++) i: root,
    };
    while (pending.isNotEmpty) {
      final next = <int, int>{};
      for (final MapEntry(key: i, value: node) in pending.entries) {
        final (data, address) = _step(keys[i], node);
        if (data != null) {
          results[i] = data;
        } else if (address != 0) {
          next[i] = address;
        }
      }
      if (next.isEmpty) break;

      final missing = {
        for (final address in next.values)
          if (!_nodes.containsKey('$version@$address')) address,
      }.toList();
      await Future.wait([
        for (var i = 0; i < missing.length; i += _rangesPerRequest)
          _prefetchChunk(
            version,
            missing.sublist(
              i,
              i + _rangesPerRequest > missing.length
                  ? missing.length
                  : i + _rangesPerRequest,
            ),
          ),
      ]);

      final entries = next.entries.toList();
      final nodes = await Future.wait(
        entries.map((entry) => getNodeAtAddress(entry.value, version)),
      );
      pending = {
        for (var i = 0; i < entries.length; i++)
          if (nodes[i] != null) entries[i].key: nodes[i]!,
      };
    }
    return results;
  }

  /// 在索引中查找 [key]，返回数据位置以及对应的索引版本。
  Future<(IndexData, String)?> search(Uint8List key) async {
    final currentVersion = await version.get();
    final root = await getNodeAtAddress(0, currentVersion);
    if (root == null) throw HitomiException.emptyRootNode();
    final data = await binarySearch(key, root, currentVersion);
    return data == null ? null : (data, currentVersion);
  }
}
