import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../atomic_json_file.dart';
import 'book_storage.dart';
import 'catalog_book.dart';
import 'catalog_store.dart';

/// Stores the catalog beside content-addressed book directories.
///
/// Writes use temporary and backup files so startup can recover after an
/// interruption between replacing the old catalog and committing the new one.
class FileCatalogStore implements CatalogStore {
  /// Creates a filesystem store at an explicit root, primarily for tests.
  FileCatalogStore(this.root);

  /// Directory containing catalog generations and imported book directories.
  final Directory root;

  late final _catalogFile = AtomicJsonFile(File('${root.path}/catalog.json'));

  /// Creates the store under the platform's private Application Support area.
  static Future<FileCatalogStore> create() async {
    final support = await getApplicationSupportDirectory();
    return FileCatalogStore(Directory('${support.path}/Reader'));
  }

  @override
  Future<List<CatalogBook>> load() async {
    await root.create(recursive: true);
    if (await FileSystemEntity.type('${root.path}/books', followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('Book storage cannot be a symbolic link.');
    }
    final stored = await _catalogFile.read((json) {
      if (json['books'] is! List) return null;
      return decodeRecords(json['books'] as List, CatalogBook.fromJson)
          .where(
            (book) =>
                ownedBookDirectory(root, book) != null &&
                File(book.path).existsSync(),
          )
          .toList();
    });
    if (stored == null) return [];
    if (stored.recovered) await save(stored.value);
    return stored.value;
  }

  @override
  Future<void> save(List<CatalogBook> books) => _catalogFile.write({
    'books': books.map((book) => book.toJson()).toList(),
  });

  @override
  Future<void> deleteFiles(CatalogBook book) async {
    final directory = ownedBookDirectory(root, book);
    if (directory == null) {
      throw const FormatException('Book path is outside owned storage.');
    }
    await directory.delete(recursive: true);
  }
}
