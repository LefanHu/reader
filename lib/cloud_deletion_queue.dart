import 'cloud_deletion_outbox.dart';

/// Single-flight drain of a durable cloud deletion outbox.
///
/// Failed deletions stay in the outbox; every drain error is swallowed so
/// privacy retries never block offline reading.
class CloudDeletionQueue {
  /// [ready] gates network work on configuration and an existing session.
  CloudDeletionQueue({
    required this._outbox,
    required this._ready,
    required this._delete,
  });

  final CloudDeletionOutbox _outbox;
  final Future<bool> Function() _ready;
  final Future<void> Function(String id) _delete;
  Future<void>? _drain;

  /// Durably records [id] without starting a drain.
  Future<void> enqueue(String id) => _outbox.enqueue(id);

  /// Whether any deletion receipt is still waiting.
  Future<bool> get hasPending async => (await _outbox.load()).isNotEmpty;

  /// Retries every pending deletion once; concurrent calls share one pass.
  Future<void> drain() =>
      _drain ??= _perform().whenComplete(() => _drain = null);

  Future<void> _perform() async {
    try {
      final items = await _outbox.load();
      if (items.isEmpty || !await _ready()) return;
      for (final item in items) {
        try {
          await _delete(item.cloudBookId);
          await _outbox.remove(item.cloudBookId);
        } on Object {
          // Keep failed requests durable for the next drain.
        }
      }
    } on Object {
      // Retries are auxiliary and must never block offline reading.
    }
  }
}
