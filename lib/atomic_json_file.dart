import 'dart:convert';
import 'dart:io';

/// Shared generation protocol for the catalog, sidecars, and deletion outbox.
///
/// Writes flush a temporary generation before moving the current file to backup.
/// Queues are shared by absolute path, including across service instances; failed
/// operations propagate to callers without preventing subsequent writes.
class AtomicJsonFile {
  /// Wraps a private app-owned file; path ownership remains the caller's policy.
  AtomicJsonFile(this.file);

  /// Committed generation and identity of the shared operation queue.
  final File file;

  /// Recovery order: committed data first, then temporary and backup generations.
  /// Callers validate each candidate against their own schema and identity.
  List<File> get generations => [
    file,
    File('${file.path}.tmp'),
    File('${file.path}.bak'),
  ];

  /// Captures a JSON snapshot immediately, then queues its atomic replacement.
  Future<void> write(Map<String, dynamic> value) {
    final body = jsonEncode(value);
    return _serialize(() => _replace(body));
  }

  /// Serializes a complete read-modify-write operation, including the read.
  /// Return null for no change; use [generations] to read and validate inside
  /// the callback. Do not call [write] or [update] from that callback.
  Future<void> update(Future<Map<String, dynamic>?> Function() change) =>
      _serialize(() async {
        final value = await change();
        if (value != null) await _replace(jsonEncode(value));
      });

  static final _operations = <String, Future<void>>{};

  Future<void> _serialize(Future<void> Function() action) {
    final key = file.absolute.path;
    final operation = (_operations[key] ?? Future<void>.value()).then(
      (_) => action(),
    );
    final tail = operation.catchError((Object _) {});
    _operations[key] = tail;
    tail.whenComplete(() {
      if (identical(_operations[key], tail)) _operations.remove(key);
    });
    return operation;
  }

  Future<void> _replace(String body) async {
    await file.parent.create(recursive: true);
    final temporary = generations[1];
    final backup = generations[2];
    await temporary.writeAsString(body, flush: true);
    // Keep the old generation recoverable until the replacement is committed.
    if (await backup.exists()) await backup.delete();
    if (await file.exists()) await file.rename(backup.path);
    await temporary.rename(file.path);
    if (await backup.exists()) await backup.delete();
  }
}
