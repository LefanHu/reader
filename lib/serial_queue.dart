/// Runs asynchronous actions one at a time in submission order.
///
/// A failed action propagates to its caller without blocking later actions.
class SerialQueue {
  Future<void> _tail = Future<void>.value();
  int _pending = 0;

  /// Number of submitted actions that have not completed yet.
  int get pending => _pending;

  /// Completes after every action submitted so far settles; never fails.
  Future<void> get idle => _tail;

  /// Queues [action] after all earlier actions and returns its result.
  Future<T> run<T>(Future<T> Function() action) {
    _pending++;
    final result = _tail.then((_) => action()).whenComplete(() => _pending--);
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
