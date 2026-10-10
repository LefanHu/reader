/// Injectable boundary for background backfill from existing normalized books.
abstract interface class BookWordCounter {
  /// Loads bounded sections sequentially, without reparsing the source book.
  Future<int> count(String sourcePath);
}
