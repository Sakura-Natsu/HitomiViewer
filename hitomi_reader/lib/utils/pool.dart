import 'dart:async';
import 'dart:collection';

/// 限制并发数量的简单任务池。
class Pool {
  Pool(this.maxConcurrent, {this.lifo = false});

  final int maxConcurrent;

  /// 为 true 时优先执行最后加入的任务（适合滚动列表中的图片加载）。
  final bool lifo;
  int _running = 0;
  final Queue<Completer<void>> _waiting = Queue();

  Future<T> run<T>(Future<T> Function() task) async {
    if (_running >= maxConcurrent) {
      final completer = Completer<void>();
      _waiting.add(completer);
      // 被唤醒时直接继承上一个任务的名额，_running 不变。
      await completer.future;
    } else {
      _running++;
    }
    try {
      return await task();
    } finally {
      if (_waiting.isNotEmpty) {
        (lifo ? _waiting.removeLast() : _waiting.removeFirst()).complete();
      } else {
        _running--;
      }
    }
  }
}
