import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/catalog/catalog_store.dart';

/// Catalog store used to verify controller behavior without filesystem I/O.
class MemoryCatalogStore implements CatalogStore {
  MemoryCatalogStore([List<CatalogBook> initial = const []])
    : books = List.of(initial);
  List<CatalogBook> books;
  final List<CatalogBook> deleted = [];
  @override
  Future<List<CatalogBook>> load() async => List.of(books);
  @override
  Future<void> save(List<CatalogBook> value) async => books = List.of(value);
  @override
  Future<void> deleteFiles(CatalogBook book) async => deleted.add(book);
}
