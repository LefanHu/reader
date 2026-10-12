// The small persistence contract is documented on its public types.
// ignore_for_file: public_member_api_docs

import 'dart:io';

import 'atomic_json_file.dart';
import 'cloud_deletion_outbox.dart';
import 'pending_book_deletion.dart';

/// Atomic JSON outbox stored outside per-book directories.
class FileCloudDeletionOutbox implements CloudDeletionOutbox {
  /// [fileName] names one feature's persisted outbox under [catalogRoot].
  FileCloudDeletionOutbox(Directory catalogRoot, {required String fileName})
    : _file = AtomicJsonFile(File('${catalogRoot.path}/$fileName'));

  final AtomicJsonFile _file;

  @override
  Future<List<PendingBookDeletion>> load() async {
    final stored = await _file.read((json) {
      if (json['items'] is! List) return null;
      return (json['items'] as List<dynamic>)
          .whereType<Map>()
          .map(
            (item) =>
                PendingBookDeletion.fromJson(item.cast<String, dynamic>()),
          )
          .toList();
    });
    return stored?.value ?? [];
  }

  @override
  Future<void> enqueue(String cloudBookId) => _file.update(() async {
    final items = await load();
    if (items.any((item) => item.cloudBookId == cloudBookId)) return null;
    return _json([
      ...items,
      PendingBookDeletion(cloudBookId: cloudBookId, queuedAt: DateTime.now()),
    ]);
  });

  @override
  Future<void> remove(String cloudBookId) => _file.update(() async {
    final items = await load();
    return _json(
      items.where((item) => item.cloudBookId != cloudBookId).toList(),
    );
  });

  Map<String, dynamic> _json(List<PendingBookDeletion> items) => {
    'items': items.map((item) => item.toJson()).toList(),
  };
}
