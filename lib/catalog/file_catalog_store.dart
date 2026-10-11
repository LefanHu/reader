import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../atomic_json_file.dart';
import '../file_cloud_deletion_outbox.dart';
import 'book_storage.dart';
import 'catalog_book.dart';
import 'catalog_store.dart';

/// Stores a versioned catalog beside content-addressed book directories.
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

  File get _reset => File('${root.path}/legacy-reset.json');

  @override
  Future<List<CatalogBook>> load() async {
    await root.create(recursive: true);
    if (await FileSystemEntity.type('${root.path}/books', followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('Book storage cannot be a symbolic link.');
    }
    if (await _reset.exists()) await _finishReset();
    var legacy = false;
    final stored = await _catalogFile.read((json) {
      if (json['books'] is! List) return null;
      if (json['version'] != 2) {
        legacy = true;
        return null;
      }
      return (json['books'] as List)
          .whereType<Map>()
          .map((item) => CatalogBook.fromJson(item.cast<String, dynamic>()))
          .where(
            (book) =>
                ownedBookDirectory(root, book) != null &&
                File(book.path).existsSync(),
          )
          .toList();
    });
    if (stored != null) {
      if (stored.recovered) await save(stored.value);
      return stored.value;
    }
    // Also clear orphaned legacy imports if their catalog was lost/corrupted.
    if (legacy || await Directory('${root.path}/books').exists()) {
      final hashes = <String>[];
      final booksRoot = Directory('${root.path}/books');
      if (await booksRoot.exists()) {
        await for (final entry in booksRoot.list(followLinks: false)) {
          final hash = entry.uri.pathSegments
              .where((part) => part.isNotEmpty)
              .last;
          if (entry is Directory && RegExp(sha256HexPattern).hasMatch(hash)) {
            hashes.add(hash);
          }
        }
      }
      // The durable marker precedes catalog replacement. Restart repeats
      // enqueue/commit/cleanup, never deleting data before privacy requests land.
      final temp = File('${_reset.path}.tmp');
      await temp.writeAsString(jsonEncode({'hashes': hashes}), flush: true);
      await temp.rename(_reset.path);
      await _finishReset();
    }
    return [];
  }

  Future<void> _finishReset() async {
    final marker = jsonDecode(await _reset.readAsString()) as Map;
    final hashes = (marker['hashes'] as List)
        .whereType<String>()
        .where((hash) => RegExp(sha256HexPattern).hasMatch(hash))
        .toList();
    final outbox = FileCloudDeletionOutbox(
      root,
      fileName: 'illustration-deletions.json',
    );
    for (final hash in hashes) {
      final directory = Directory('${root.path}/books/$hash');
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      for (final suffix in ['', '.tmp', '.bak']) {
        final sidecar = File('${directory.path}/visuals/manifest.json$suffix');
        // Never follow a manipulated legacy sidecar outside app-owned storage.
        if (await FileSystemEntity.type(
                  '${directory.path}/visuals',
                  followLinks: false,
                ) !=
                FileSystemEntityType.directory ||
            await FileSystemEntity.type(sidecar.path, followLinks: false) !=
                FileSystemEntityType.file) {
          continue;
        }
        try {
          final manifest = jsonDecode(await sidecar.readAsString()) as Map;
          final id = (manifest['profile'] as Map?)?['cloudBookId'];
          if (id is String && id.isNotEmpty) await outbox.enqueue(id);
        } on FormatException {
          continue;
        } on TypeError {
          continue;
        }
      }
    }
    // Narration sidecars are additive, but their cloud privacy receipts must
    // survive a legacy reset just like illustration receipts.
    final narrationOutbox = FileCloudDeletionOutbox(
      root,
      fileName: 'narration-deletions.json',
    );
    for (final hash in hashes) {
      final path = '${root.path}/books/$hash/narration';
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      for (final suffix in ['', '.tmp', '.bak']) {
        final file = File('$path/manifest.json$suffix');
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          continue;
        }
        try {
          final id =
              (jsonDecode(await file.readAsString()) as Map)['cloudBookId'];
          if (id is String && RegExp(sha256HexPattern).hasMatch(id)) {
            await narrationOutbox.enqueue(id);
          }
        } on Object {
          /* Corrupt generations cannot authorize external deletion. */
        }
      }
    }
    await save([]);
    for (final hash in hashes) {
      final directory = Directory('${root.path}/books/$hash');
      if (await FileSystemEntity.type(directory.path, followLinks: false) ==
          FileSystemEntityType.directory) {
        await directory.delete(recursive: true);
      }
    }
    await _reset.delete();
  }

  @override
  Future<void> save(List<CatalogBook> books) => _catalogFile.write({
    'version': 2,
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
