import 'serial_queue.dart';

/// Serializes actions per key; distinct keys run independently.
///
/// Idle keys are dropped so unbounded key spaces (per-book paths) do not leak.
class KeyedSerialQueue {
  final _queues = <String, SerialQueue>{};

  /// Queues [action] after earlier actions with the same [key].
  Future<T> run<T>(String key, Future<T> Function() action) {
    final queue = _queues.putIfAbsent(key, SerialQueue.new);
    final result = queue.run(action);
    queue.idle.then((_) {
      if (queue.pending == 0 && identical(_queues[key], queue)) {
        _queues.remove(key);
      }
    });
    return result;
  }
}
