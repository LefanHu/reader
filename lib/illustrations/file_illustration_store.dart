// The persistence lifecycle is documented on IllustrationStore and its file implementation.
// ignore_for_file: public_member_api_docs

import 'dart:convert';
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

  /// Loads the schema-2 manifest, discarding obsolete illustration state first.
  ///
  /// Schema is inspected across the committed, temporary and backup generations
  /// before any legacy profile is interpreted; a valid v2 generation always wins
  /// over an obsolete backup. Only decodable manifests of this book with a
  /// missing or older version trigger discard, and then only this book's owned
  /// `visuals` directory is removed (manifest, index, images, recovery files)
  /// before a fresh disabled v2 manifest is written. Future schemas, links and
  /// paths outside owned storage are left untouched and read as disabled.
  /// Cleanup failure also reads as disabled; legacy evidence remains, so the
  /// next load retries, and legacy consent is never enabled.
  @override
  Future<IllustrationManifest> loadManifest(CatalogBook book) async {
    final fresh = IllustrationManifest(bookHash: book.hash);
    final Directory visuals;
    final AtomicJsonFile file;
    try {
      visuals = _root(book);
      file = _manifest(book);
    } on FormatException {
      return fresh;
    }
    final stored = await file.read((json) {
      if (json['version'] != 2 || json['bookHash'] != book.hash) return null;
      return IllustrationManifest.fromJson(json);
    });
    if (stored != null) return stored.value;
    if (!await _hasObsoleteState(visuals, book.hash)) return fresh;
    try {
      await visuals.delete(recursive: true);
      await saveManifest(book, fresh);
    } on FileSystemException {
      // Retried on the next load while the obsolete evidence still exists.
    }
    return fresh;
  }

  /// True only for this book's decodable pre-v2 manifest in an all-regular tree.
  Future<bool> _hasObsoleteState(Directory visuals, String bookHash) async {
    if (await FileSystemEntity.type(visuals.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    await for (final entry in visuals.list(
      recursive: true,
      followLinks: false,
    )) {
      if (await FileSystemEntity.isLink(entry.path)) return false;
    }
    var obsolete = false;
    for (final suffix in ['', '.tmp', '.bak']) {
      final candidate = File('${visuals.path}/manifest.json$suffix');
      if (await FileSystemEntity.type(candidate.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      try {
        final json = jsonDecode(await candidate.readAsString());
        if (json is! Map || json['bookHash'] != bookHash) continue;
        final version = json['version'];
        // A future schema is never downgraded or erased by this build.
        if (version is int && version > 2) return false;
        if (version == null || (version is int && version < 2)) obsolete = true;
      } on Object {
        continue;
      }
    }
    return obsolete;
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
      return value.version == 2 && value.bookHash == book.hash ? value : null;
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
    required int generationVersion,
    bool thumbnail = false,
  }) async {
    if (!_sceneId.hasMatch(sceneId)) {
      throw const FormatException('Invalid illustration scene identity.');
    }
    if (generationVersion < 1) {
      throw const FormatException('Invalid illustration generation version.');
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
    final destination = File(
      '${images.path}/$sceneId.v$generationVersion.$suffix',
    );
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
    int? generationVersion,
  }) async {
    // An invalid identity can never have been saved.
    if (!_sceneId.hasMatch(sceneId)) return;
    if (generationVersion != null && generationVersion < 1) {
      throw const FormatException('Invalid illustration generation version.');
    }
    final images = _images(book);
    if (!await images.exists()) return;
    final ownedName = RegExp(
      '^$sceneId\\.v([1-9][0-9]*)\\.(?:png|jpg|webp|thumb\\.webp)(?:\\.tmp)?\$',
    );
    await for (final entry in images.list(followLinks: false)) {
      final match = ownedName.firstMatch(entry.uri.pathSegments.last);
      if (match == null ||
          (generationVersion != null &&
              match.group(1) != generationVersion.toString())) {
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
