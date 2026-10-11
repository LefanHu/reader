// The persistence lifecycle is documented on IllustrationStore and its file implementation.
// ignore_for_file: public_member_api_docs

import 'dart:io';
import 'dart:typed_data';

import '../atomic_json_file.dart';
import '../catalog/book_storage.dart';
import '../catalog/catalog_book.dart';
import 'book_text_index.dart';
import 'illustration_manifest.dart';
import 'store.dart';

/// Stores sidecars under `<book directory>/visuals` without touching the source book.
///
/// Only books inside the owned catalog [root] are accepted, and scene IDs must
/// be cloud-issued 40-hex identities before they become file names.
class FileIllustrationStore implements IllustrationStore {
  FileIllustrationStore(this.root);

  /// Private catalog root that owns every book directory.
  final Directory root;

  static final _sceneId = RegExp(r'^[a-f0-9]{40}$');

  Directory _root(CatalogBook book) => featureDirectory(root, book, 'visuals');

  AtomicJsonFile _manifest(CatalogBook book) =>
      AtomicJsonFile(File('${_root(book).path}/manifest.json'));
  AtomicJsonFile _index(CatalogBook book) =>
      AtomicJsonFile(File('${_root(book).path}/index.json'));

  @override
  Future<IllustrationManifest> loadManifest(CatalogBook book) async {
    final AtomicJsonFile file;
    try {
      file = _manifest(book);
    } on FormatException {
      return IllustrationManifest(bookHash: book.hash);
    }
    final stored = await file.read((json) {
      final value = IllustrationManifest.fromJson(json);
      return value.version == 1 && value.bookHash == book.hash ? value : null;
    });
    return stored?.value ?? IllustrationManifest(bookHash: book.hash);
  }

  @override
  Future<void> saveManifest(CatalogBook book, IllustrationManifest manifest) =>
      _manifest(book).write(manifest.toJson());

  @override
  Future<BookTextIndex?> loadIndex(CatalogBook book) async {
    final AtomicJsonFile file;
    try {
      file = _index(book);
    } on FormatException {
      return null;
    }
    final stored = await file.read((json) {
      final value = BookTextIndex.fromJson(json);
      return value.version == 1 && value.bookHash == book.hash ? value : null;
    });
    return stored?.value;
  }

  @override
  Future<void> saveIndex(CatalogBook book, BookTextIndex index) =>
      _index(book).write(index.toJson());

  @override
  Future<String> saveImage(
    CatalogBook book,
    String sceneId,
    Uint8List bytes, {
    bool thumbnail = false,
  }) async {
    if (!_sceneId.hasMatch(sceneId)) {
      throw const FormatException('Invalid illustration scene identity.');
    }
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
    // An invalid identity can never have been saved.
    if (!_sceneId.hasMatch(sceneId)) return;
    final images = Directory('${_root(book).path}/images');
    for (final suffix in ['.webp', '.thumb.webp']) {
      final file = File('${images.path}/$sceneId$suffix');
      if (await file.exists()) await file.delete();
    }
  }
}
