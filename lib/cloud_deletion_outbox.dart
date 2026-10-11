import 'pending_book_deletion.dart';

/// Durable boundary for privacy-sensitive cloud deletion retries.
abstract interface class CloudDeletionOutbox {
  /// Pending receipts in enqueue order; empty when none were persisted.
  Future<List<PendingBookDeletion>> load();

  /// Records [cloudBookId] once; duplicates are ignored.
  Future<void> enqueue(String cloudBookId);

  /// Drops the receipt after the server confirmed deletion.
  Future<void> remove(String cloudBookId);
}
