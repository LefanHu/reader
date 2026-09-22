import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

abstract interface class CatalogStore {
  Future<List<CatalogBook>> load();
  Future<void> save(List<CatalogBook> books);
  Future<void> deleteFiles(CatalogBook book);
}

class FileCatalogStore implements CatalogStore {
  FileCatalogStore(this.root);
  final Directory root;

  File get _catalog => File('${root.path}/catalog.json');
  File get _temporary => File('${root.path}/catalog.json.tmp');
  File get _backup => File('${root.path}/catalog.json.bak');

  static Future<FileCatalogStore> create() async {
    final support = await getApplicationSupportDirectory();
    return FileCatalogStore(Directory('${support.path}/Reader'));
  }

  @override
  Future<List<CatalogBook>> load() async {
    await root.create(recursive: true);
    for (final candidate in [_catalog, _temporary, _backup]) {
      if (!await candidate.exists()) continue;
      try {
        final json = jsonDecode(await candidate.readAsString());
        if (json is! Map || json['version'] != 1 || json['books'] is! List) {
          continue;
        }
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

abstract interface class SettingsStore {
  Future<ReaderSettings> load();
  Future<void> save(ReaderSettings settings);
}

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
      return const ReaderSettings();
    }
  }

  @override
  Future<void> save(ReaderSettings settings) =>
      _preferences.setString(_key, jsonEncode(settings.toJson()));
}
