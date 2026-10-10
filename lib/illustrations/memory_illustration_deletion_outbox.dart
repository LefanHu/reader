// The small persistence contract is documented on its public types.
// ignore_for_file: public_member_api_docs

import 'outbox.dart';
import 'pending_book_deletion.dart';

/// In-memory default for custom controller graphs that do not own a root.
class MemoryIllustrationDeletionOutbox implements IllustrationDeletionOutbox {
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
