// The small persistence contract is documented on its public types.
// ignore_for_file: public_member_api_docs

import 'package:reader/cloud_deletion_outbox.dart';
import 'package:reader/pending_book_deletion.dart';

/// In-memory outbox for test controller graphs that do not own a root.
class MemoryCloudDeletionOutbox implements CloudDeletionOutbox {
  final List<PendingBookDeletion> _items = [];

  @override
  Future<void> enqueue(String cloudBookId) async {
    if (_items.any((item) => item.cloudBookId == cloudBookId)) return;
    _items.add(
      PendingBookDeletion(cloudBookId: cloudBookId, queuedAt: DateTime.now()),
    );
  }

  @override
  Future<List<PendingBookDeletion>> load() async => List.of(_items);

  @override
  Future<void> remove(String cloudBookId) async {
    _items.removeWhere((item) => item.cloudBookId == cloudBookId);
  }
}
