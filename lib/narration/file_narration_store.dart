import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../atomic_json_file.dart';
import '../catalog/catalog_book.dart';
import 'narration_manifest.dart';
import 'store.dart';

/// Filesystem implementation restricted to the content-addressed catalog root.
class FileNarrationStore implements NarrationStore {
  /// The catalog root is injected; cache eviction never follows symlinks.
  FileNarrationStore(this.root, {this.maxBytes = 250 * 1024 * 1024});

  /// Private catalog root, shared with imports and durable deletion requests.
  final Directory root;

  /// Global byte budget; active files may briefly exceed it until unpinned.
  final int maxBytes;
  Set<String> _pins = {};
  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Directory _directory(CatalogBook book) {
    final parent = File(book.path).absolute.parent;
    final expected = '${root.absolute.path}/books/${book.hash}';
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(book.hash) ||
        parent.path != expected ||
        FileSystemEntity.typeSync('${root.path}/books', followLinks: false) !=
            FileSystemEntityType.directory ||
        FileSystemEntity.typeSync(parent.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const FormatException('Narration path is outside owned storage.');
    }
    final directory = Directory('$expected/narration');
    final kind = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (kind != FileSystemEntityType.notFound &&
        kind != FileSystemEntityType.directory) {
      throw const FormatException('Narration storage cannot be a link.');
    }
    return directory;
  }

  File _audio(CatalogBook book, String key) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw const FormatException('Invalid audio key.');
    }
    final file = File('${_directory(book).path}/$key.wav');
    if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('Audio cannot be a link.');
    }
    return file;
  }

  @override
  Future<NarrationManifest> load(CatalogBook book) => _serial(() async {
    for (final file in AtomicJsonFile(
      File('${_directory(book).path}/manifest.json'),
    ).generations) {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      try {
        final json = (jsonDecode(await file.readAsString()) as Map)
            .cast<String, dynamic>();
        if (json['bookHash'] != book.hash) continue;
        return NarrationManifest.fromJson(json);
      } on Object {
        continue;
      }
    }
    return const NarrationManifest();
  });
  @override
  Future<void> save(CatalogBook book, NarrationManifest manifest) =>
      _serial(() async {
        final directory = _directory(book);
        await directory.create();
        // Bind consent/resume to the source; a copied sidecar cannot carry
        // another publication's registration into this owned directory.
        await AtomicJsonFile(File('${directory.path}/manifest.json'))
            .write({'bookHash': book.hash, ...manifest.toJson()});
      });
  @override
  Future<String?> cached(CatalogBook book, String key) => _serial(() async {
    final file = _audio(book, key);
    if (!await file.exists()) return null;
    await file.setLastModified(DateTime.now());
    return file.path;
  });
  @override
  Future<String> put(CatalogBook book, String key, Uint8List bytes) =>
      _serial(() async {
        if (bytes.length < 44 ||
            bytes.length > 32 * 1024 * 1024 ||
            ascii.decode(bytes.take(4).toList()) != 'RIFF' ||
            ascii.decode(bytes.skip(8).take(4).toList()) != 'WAVE') {
          throw const FormatException('Invalid narration WAV.');
        }
        final file = _audio(book, key);
        await file.parent.create();
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename(file.path);
        await _evict();
        return file.path;
      });
  @override
  void pin(Set<String> keys) {
    _pins = Set.of(keys);
  }

  Future<void> _evict() async {
    final files = <File>[];
    final books = Directory('${root.path}/books');
    if (!await books.exists()) return;
    await for (final book in books.list(followLinks: false)) {
      if (book is! Directory) continue;
      final path = '${book.path}/narration';
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      await for (final file in Directory(path).list(followLinks: false)) {
        if (file is File &&
            RegExp(r'/[a-f0-9]{64}\.wav$').hasMatch(file.path)) {
          files.add(file);
        }
      }
    }
    final stats = {for (final file in files) file: await file.stat()};
    files.sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));
    var total = stats.values.fold(0, (sum, stat) => sum + stat.size);
    for (final file in files) {
      if (total <= maxBytes) break;
      final key = file.uri.pathSegments.last.split('.').first;
      if (_pins.contains(key)) continue;
      await file.delete();
      total -= stats[file]!.size;
    }
  }

  @override
  Future<int> cachedBytes(CatalogBook book) => _serial(() async {
    final directory = _directory(book);
    if (!await directory.exists()) return 0;
    var bytes = 0;
    await for (final file in directory.list(followLinks: false)) {
      if (file is File &&
          RegExp(r'/[a-f0-9]{64}\.wav$').hasMatch(file.path) &&
          await FileSystemEntity.type(file.path, followLinks: false) ==
              FileSystemEntityType.file) {
        bytes += await file.length();
      }
    }
    return bytes;
  });

  @override
  Future<void> clear(CatalogBook book) => _serial(() async {
    final directory = _directory(book);
    if (!await directory.exists()) return;
    await for (final file in directory.list(followLinks: false)) {
      if (file is File &&
          RegExp(r'/[a-f0-9]{64}\.wav(?:\.tmp)?$').hasMatch(file.path)) {
        await file.delete();
      }
    }
  });
}
