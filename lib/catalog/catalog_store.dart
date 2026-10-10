import 'catalog_book.dart';

/// Persistence boundary for imported book records and their private files.
abstract interface class CatalogStore {
  /// Restores valid catalog records, applying any recovery policy.
  Future<List<CatalogBook>> load();

  /// Atomically persists the complete catalog snapshot.
  Future<void> save(List<CatalogBook> books);

  /// Deletes the private content directory owned by [book].
  Future<void> deleteFiles(CatalogBook book);
}
