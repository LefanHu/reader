import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'atomic_json_file.dart';
import 'illustrations/outbox.dart';

/// Persistence boundary for imported book records and their private files.
abstract interface class CatalogStore {
  /// Restores valid catalog records, applying any recovery policy.
  Future<List<CatalogBook>> load();

  /// Atomically persists the complete catalog snapshot.
  Future<void> save(List<CatalogBook> books);

  /// Deletes the private content directory owned by [book].
  Future<void> deleteFiles(CatalogBook book);
}

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
    for (final candidate in _catalogFile.generations) {
      if (!await candidate.exists()) continue;
      try {
        final json = jsonDecode(await candidate.readAsString());
        if (json is! Map || json['books'] is! List) continue;
        if (json['version'] != 2) {
          legacy = true;
          continue;
        }
        final books = (json['books'] as List)
            .whereType<Map>()
            .map((item) => CatalogBook.fromJson(item.cast<String, dynamic>()))
            .where(
              (book) =>
                  _ownedDirectory(book) != null && File(book.path).existsSync(),
            )
            .toList();
        if (candidate.path != _catalogFile.file.path) await save(books);
        return books;
      } on Object {
        continue;
      }
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
          if (entry is Directory && RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
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
        .where((hash) => RegExp(r'^[a-f0-9]{64}$').hasMatch(hash))
        .toList();
    final outbox = FileIllustrationDeletionOutbox(root);
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
    final narrationOutbox = FileIllustrationDeletionOutbox(
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
          if (id is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
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

  Directory? _ownedDirectory(CatalogBook book) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(book.hash)) return null;
    if (FileSystemEntity.typeSync('${root.path}/books', followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    final expected = Directory('${root.absolute.path}/books/${book.hash}');
    if (File(book.path).absolute.parent.path != expected.path) return null;
    if (FileSystemEntity.typeSync(expected.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    return expected;
  }

  @override
  Future<void> deleteFiles(CatalogBook book) async {
    final directory = _ownedDirectory(book);
    if (directory == null) {
      throw const FormatException('Book path is outside owned storage.');
    }
    await directory.delete(recursive: true);
  }
}

/// Persistence boundary for preferences that apply across publications.
abstract interface class SettingsStore {
  /// Restores global settings or their defaults.
  Future<ReaderSettings> load();

  /// Persists the complete global settings value.
  Future<void> save(ReaderSettings settings);
}

/// Stores global reader settings as one JSON value in SharedPreferences.
class PreferenceSettingsStore implements SettingsStore {
  static const _key = 'reader.settings.v1';
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();

  @override
  Future<ReaderSettings> load() async {
    final value = await _preferences.getString(_key);
    if (value == null) return const ReaderSettings();
    try {
      return ReaderSettings.fromJson(
        (jsonDecode(value) as Map).cast<String, dynamic>(),
      );
    } on Object {
      // A corrupt or older value must not prevent the library from opening.
      return const ReaderSettings();
    }
  }

  @override
  Future<void> save(ReaderSettings settings) =>
      _preferences.setString(_key, jsonEncode(settings.toJson()));
}
