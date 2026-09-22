import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Persistence boundary for imported book records and their private files.
abstract interface class CatalogStore {
  /// Restores valid catalog records, applying any recovery policy.
  Future<List<CatalogBook>> load();

  /// Atomically persists the complete catalog snapshot.
  Future<void> save(List<CatalogBook> books);

  /// Deletes the private content directory owned by [book].
  Future<void> deleteFiles(CatalogBook book);
}

/// Stores a versioned catalog beside content-addressed EPUB directories.
///
/// Writes use temporary and backup files so startup can recover after an
/// interruption between replacing the old catalog and committing the new one.
class FileCatalogStore implements CatalogStore {
  /// Creates a filesystem store at an explicit root, primarily for tests.
  FileCatalogStore(this.root);

  /// Directory containing catalog generations and imported book directories.
  final Directory root;

  File get _catalog => File('${root.path}/catalog.json');
  File get _temporary => File('${root.path}/catalog.json.tmp');
  File get _backup => File('${root.path}/catalog.json.bak');

  /// Creates the store under the platform's private Application Support area.
  static Future<FileCatalogStore> create() async {
    final support = await getApplicationSupportDirectory();
    return FileCatalogStore(Directory('${support.path}/Reader'));
  }

  @override
  Future<List<CatalogBook>> load() async {
    await root.create(recursive: true);
    // Prefer the committed file, then recover an interrupted write or backup.
    for (final candidate in [_catalog, _temporary, _backup]) {
      if (!await candidate.exists()) continue;
      try {
        final json = jsonDecode(await candidate.readAsString());
        if (json is! Map || json['version'] != 1 || json['books'] is! List) {
          continue;
        }
        // Catalog entries whose EPUB disappeared are not shown as broken books.
        final books = (json['books'] as List)
            .whereType<Map>()
            .map((item) => CatalogBook.fromJson(item.cast<String, dynamic>()))
            .where((book) => File(book.path).existsSync())
            .toList();
        if (candidate.path != _catalog.path) await save(books);
        return books;
      } on Object {
        continue;
      }
    }
    return [];
  }

  @override
  Future<void> save(List<CatalogBook> books) async {
    await root.create(recursive: true);
    final body = jsonEncode({
      'version': 1,
      'books': books.map((book) => book.toJson()).toList(),
    });
    // Keep one recoverable generation until the replacement is committed.
    await _temporary.writeAsString(body, flush: true);
    if (await _backup.exists()) await _backup.delete();
    if (await _catalog.exists()) await _catalog.rename(_backup.path);
    await _temporary.rename(_catalog.path);
    if (await _backup.exists()) await _backup.delete();
  }

  @override
  Future<void> deleteFiles(CatalogBook book) async {
    final directory = File(book.path).parent;
    if (await directory.exists()) await directory.delete(recursive: true);
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
