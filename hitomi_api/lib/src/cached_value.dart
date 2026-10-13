/// 带过期时间的异步缓存，并发调用时只会触发一次请求。
///
/// 对应 node-hitomi 的 `Provider<T>`。
class CachedValue<T> {
  CachedValue(this._fetch, this.maxAge);

  final Future<T> Function() _fetch;

  /// 为 [Duration.zero] 时不缓存，每次都重新获取（并发请求仍会合并）。
  final Duration maxAge;

  T? _value;
  DateTime? _expiresAt;
  Future<T>? _pending;

  bool get _isFresh {
    final expiresAt = _expiresAt;
    return expiresAt != null && DateTime.now().isBefore(expiresAt);
  }

  Future<T> get({bool forceRefresh = false}) {
    if (!forceRefresh && _isFresh) return Future.value(_value as T);
    return _pending ??= _load();
  }

  Future<T> _load() async {
    try {
      final value = await _fetch();
      _value = value;
      _expiresAt = maxAge == Duration.zero ? null : DateTime.now().add(maxAge);
      return value;
    } finally {
      _pending = null;
    }
  }

  void invalidate() => _expiresAt = null;
}
