// The persistence lifecycle is documented on IllustrationStore and its file implementation.
// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models.dart';
import 'models.dart';

/// Atomic persistence boundary for illustration manifests, indexes, and art.
abstract interface class IllustrationStore {
  Future<IllustrationManifest> loadManifest(CatalogBook book);
  Future<void> saveManifest(CatalogBook book, IllustrationManifest manifest);
  Future<BookTextIndex?> loadIndex(CatalogBook book);
  Future<void> saveIndex(CatalogBook book, BookTextIndex index);
  Future<String> saveImage(
    CatalogBook book,
    String sceneId,
    Uint8List bytes, {
    bool thumbnail,
  });
  Future<void> deleteSceneFiles(CatalogBook book, String sceneId);
}

/// Stores sidecars under `<book directory>/visuals` without touching the EPUB.
class FileIllustrationStore implements IllustrationStore {
  Directory _root(CatalogBook book) =>
      Directory('${File(book.path).parent.path}/visuals');

  File _manifest(CatalogBook book) => File('${_root(book).path}/manifest.json');
  File _index(CatalogBook book) => File('${_root(book).path}/index.json');

  @override
  Future<IllustrationManifest> loadManifest(CatalogBook book) async {
    final file = _manifest(book);
    for (final candidate in _generations(file)) {
      if (!await candidate.exists()) continue;
      try {
        final json = (jsonDecode(await candidate.readAsString()) as Map)
            .cast<String, dynamic>();
        final value = IllustrationManifest.fromJson(json);
        if (value.version == 1 && value.bookHash == book.hash) return value;
      } on Object {
        continue;
      }
    }
    return IllustrationManifest(bookHash: book.hash);
  }

  @override
  Future<void> saveManifest(CatalogBook book, IllustrationManifest manifest) =>
      _atomicJson(_manifest(book), manifest.toJson());

  @override
  Future<BookTextIndex?> loadIndex(CatalogBook book) async {
    final file = _index(book);
    for (final candidate in _generations(file)) {
      if (!await candidate.exists()) continue;
      try {
        final value = BookTextIndex.fromJson(
          (jsonDecode(await candidate.readAsString()) as Map)
              .cast<String, dynamic>(),
        );
        if (value.version == 1 && value.bookHash == book.hash) return value;
      } on Object {
        continue;
      }
    }
    return null;
  }

  @override
  Future<void> saveIndex(CatalogBook book, BookTextIndex index) =>
      _atomicJson(_index(book), index.toJson());

  @override
  Future<String> saveImage(
    CatalogBook book,
    String sceneId,
    Uint8List bytes, {
    bool thumbnail = false,
  }) async {
    final images = Directory('${_root(book).path}/images');
    await images.create(recursive: true);
    final suffix = thumbnail ? '.thumb.webp' : '.webp';
    final destination = File('${images.path}/$sceneId$suffix');
    final temporary = File('${destination.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    if (await destination.exists()) await destination.delete();
    await temporary.rename(destination.path);
    return destination.path;
  }

  @override
  Future<void> deleteSceneFiles(CatalogBook book, String sceneId) async {
    final images = Directory('${_root(book).path}/images');
    for (final suffix in ['.webp', '.thumb.webp']) {
      final file = File('${images.path}/$sceneId$suffix');
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _atomicJson(File destination, Map<String, dynamic> json) async {
    await destination.parent.create(recursive: true);
    final temporary = File('${destination.path}.tmp');
    final backup = File('${destination.path}.bak');
    await temporary.writeAsString(jsonEncode(json), flush: true);
    if (await backup.exists()) await backup.delete();
    if (await destination.exists()) await destination.rename(backup.path);
    await temporary.rename(destination.path);
    if (await backup.exists()) await backup.delete();
  }

  List<File> _generations(File destination) => [
    destination,
    File('${destination.path}.tmp'),
    File('${destination.path}.bak'),
  ];
}
