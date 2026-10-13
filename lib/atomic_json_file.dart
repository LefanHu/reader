import 'dart:convert';
import 'dart:io';

import 'keyed_serial_queue.dart';

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

  static final _queue = KeyedSerialQueue();

  /// Recovery order: committed data first, then temporary and backup generations.
  List<File> get _generations => [
    file,
    File('${file.path}.tmp'),
    File('${file.path}.bak'),
  ];

  /// Returns the first generation that is a regular file holding a JSON object
  /// accepted by [decode] (non-null, no exception), or null when none is.
  ///
  /// `recovered` is true when the committed file was unusable. Not serialized:
  /// it is safe to call from an [update] callback on the same path.
  Future<({T value, bool recovered})?> read<T>(
    T? Function(Map<String, dynamic> json) decode,
  ) async {
    final generations = _generations;
    for (var index = 0; index < generations.length; index++) {
      final candidate = generations[index];
      if (await FileSystemEntity.type(candidate.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      try {
        final json = jsonDecode(await candidate.readAsString());
        if (json is! Map) continue;
        final value = decode(json.cast<String, dynamic>());
        if (value != null) return (value: value, recovered: index > 0);
      } on Object {
        continue;
      }
    }
    return null;
  }

  /// Captures a JSON snapshot immediately, then queues its atomic replacement.
  Future<void> write(Map<String, dynamic> value) {
    final body = jsonEncode(value);
    return _queue.run(file.absolute.path, () => _replace(body));
  }

  /// Serializes a complete read-modify-write operation, including the read.
  /// Return null for no change; use [read] to read and validate inside the
  /// callback. Do not call [write] or [update] from that callback. An optional
  /// [isCurrent] fence is rechecked after each preparation await and immediately
  /// before the synchronous commit, so invalidated work cannot publish late.
  Future<void> update(
    Future<Map<String, dynamic>?> Function() change, {
    bool Function()? isCurrent,
  }) => _queue.run(file.absolute.path, () async {
    if (isCurrent != null && !isCurrent()) return;
    final value = await change();
    if (value != null) {
      await _replace(jsonEncode(value), isCurrent: isCurrent);
    }
  });

  Future<void> _replace(String body, {bool Function()? isCurrent}) async {
    if (isCurrent != null) {
      await _replaceFenced(body, isCurrent);
      return;
    }
    await file.parent.create(recursive: true);
    final temporary = _generations[1];
    final backup = _generations[2];
    await temporary.writeAsString(body, flush: true);
    // Keep the old generation recoverable until the replacement is committed.
    if (await backup.exists()) await backup.delete();
    if (await file.exists()) await file.rename(backup.path);
    await temporary.rename(file.path);
    if (await backup.exists()) await backup.delete();
  }

  Future<void> _replaceFenced(String body, bool Function() isCurrent) async {
    if (!isCurrent()) return;
    await file.parent.create(recursive: true);
    if (!isCurrent()) return;
    final temporary = _generations[1];
    final backup = _generations[2];
    await temporary.writeAsString(body, flush: true);
    if (!isCurrent()) {
      // This path's queue is held: no other writer can own this temporary file.
      temporary.deleteSync();
      return;
    }
    // No event-loop gap between the final ownership check and publication.
    if (backup.existsSync()) backup.deleteSync();
    if (file.existsSync()) file.renameSync(backup.path);
    temporary.renameSync(file.path);
    if (backup.existsSync()) backup.deleteSync();
  }
}

/// Decodes each map in a persisted list independently, skipping records that
/// no longer parse. One malformed record must never invalidate the whole file:
/// [AtomicJsonFile.read] would discard it and the next write would silently
/// drop every valid record, including deletion receipts kept for retry.
List<T> decodeRecords<T>(
  List<dynamic> items,
  T Function(Map<String, dynamic> json) decode,
) {
  final records = <T>[];
  for (final item in items.whereType<Map>()) {
    try {
      records.add(decode(item.cast<String, dynamic>()));
    } on Object {
      continue;
    }
  }
  return records;
}
