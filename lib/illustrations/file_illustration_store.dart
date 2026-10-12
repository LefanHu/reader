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

  /// Loads this book's manifest; unreadable or foreign manifests read as a fresh disabled manifest.
  @override
  Future<IllustrationManifest> loadManifest(CatalogBook book) async {
    final fresh = IllustrationManifest(bookHash: book.hash);
    final AtomicJsonFile file;
    try {
      file = _manifest(book);
    } on FormatException {
      return fresh;
    }
    final stored = await file.read((json) {
      if (json['bookHash'] != book.hash) return null;
      return IllustrationManifest.fromJson(json);
    });
    return stored?.value ?? fresh;
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
      return value.bookHash == book.hash ? value : null;
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
    required String mimeType,
    required int generation,
    bool thumbnail = false,
  }) async {
    if (!_sceneId.hasMatch(sceneId)) {
      throw const FormatException('Invalid illustration scene identity.');
    }
    if (generation < 1) {
      throw const FormatException('Invalid illustration generation.');
    }
    final extension = switch (mimeType) {
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      _ => throw const FormatException('Invalid illustration image MIME.'),
    };
    if (thumbnail && mimeType != 'image/webp') {
      throw const FormatException(
        'Derived illustration thumbnails must be WebP.',
      );
    }
    final images = _images(book);
    await images.create(recursive: true);
    final suffix = thumbnail ? 'thumb.webp' : extension;
    final destination = File('${images.path}/$sceneId.$generation.$suffix');
    final temporary = File('${destination.path}.tmp');
    for (final file in [destination, temporary]) {
      final kind = await FileSystemEntity.type(file.path, followLinks: false);
      if (kind != FileSystemEntityType.notFound &&
          kind != FileSystemEntityType.file) {
        throw const FormatException(
          'Illustration assets must be regular files.',
        );
      }
    }
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(destination.path);
    return destination.path;
  }

  @override
  Future<void> deleteSceneFiles(
    CatalogBook book,
    String sceneId, {
    int? generation,
  }) async {
    // An invalid identity can never have been saved.
    if (!_sceneId.hasMatch(sceneId)) return;
    if (generation != null && generation < 1) {
      throw const FormatException('Invalid illustration generation.');
    }
    final images = _images(book);
    if (!await images.exists()) return;
    final ownedName = RegExp(
      '^$sceneId\\.([1-9][0-9]*)\\.(?:png|jpg|webp|thumb\\.webp)(?:\\.tmp)?\$',
    );
    await for (final entry in images.list(followLinks: false)) {
      final match = ownedName.firstMatch(entry.uri.pathSegments.last);
      if (match == null ||
          (generation != null && match.group(1) != generation.toString())) {
        continue;
      }
      if (await FileSystemEntity.type(entry.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await entry.delete();
      }
    }
  }

  Directory _images(CatalogBook book) {
    final images = Directory('${_root(book).path}/images');
    final kind = FileSystemEntity.typeSync(images.path, followLinks: false);
    if (kind != FileSystemEntityType.notFound &&
        kind != FileSystemEntityType.directory) {
      throw const FormatException(
        'Illustration image storage cannot be a link.',
      );
    }
    return images;
  }
}
