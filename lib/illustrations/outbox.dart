// The small persistence contract is documented on its public types.
// ignore_for_file: public_member_api_docs

import 'pending_book_deletion.dart';

/// Durable boundary for privacy-sensitive cloud deletion retries.
abstract interface class IllustrationDeletionOutbox {
  Future<List<PendingBookDeletion>> load();
  Future<void> enqueue(String cloudBookId);
  Future<void> remove(String cloudBookId);
}
