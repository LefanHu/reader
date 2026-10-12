import 'dart:typed_data';

import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/illustrations/book_text_index.dart';
import 'package:reader/illustrations/illustration_manifest.dart';
import 'package:reader/illustrations/store.dart';

/// Illustration sidecar store that keeps widget tests off the filesystem.
class MemoryIllustrationStore implements IllustrationStore {
  final Map<String, IllustrationManifest> manifests = {};
  final Map<String, BookTextIndex> indexes = {};
  final Map<String, Uint8List> images = {};
  static final _sceneId = RegExp(r'^[a-f0-9]{40}$');

  @override
  Future<void> deleteSceneFiles(
    CatalogBook book,
    String sceneId, {
    int? generationVersion,
  }) async {
    if (!_sceneId.hasMatch(sceneId)) return;
    if (generationVersion != null && generationVersion < 1) {
      throw const FormatException('Invalid illustration generation version.');
    }
    final ownedName = RegExp(
      '^$sceneId\\.v([1-9][0-9]*)\\.(?:png|jpg|webp|thumb\\.webp)\$',
    );
    final prefix = '/memory/${book.hash}/';
    images.removeWhere((path, _) {
      if (!path.startsWith(prefix)) return false;
      final match = ownedName.firstMatch(path.substring(prefix.length));
      return match != null &&
          (generationVersion == null ||
              match.group(1) == generationVersion.toString());
    });
  }

  @override
  Future<BookTextIndex?> loadIndex(CatalogBook book) async =>
      indexes[book.hash];

  @override
  Future<IllustrationManifest> loadManifest(CatalogBook book) async =>
      manifests[book.hash] ?? IllustrationManifest(bookHash: book.hash);

  @override
  Future<void> saveIndex(CatalogBook book, BookTextIndex index) async {
    indexes[book.hash] = index;
  }

  @override
  Future<String> saveImage(
    CatalogBook book,
    String sceneId,
    Uint8List bytes, {
    required String mimeType,
    required int generationVersion,
    bool thumbnail = false,
  }) async {
    if (!_sceneId.hasMatch(sceneId) || generationVersion < 1) {
      throw const FormatException('Invalid illustration asset identity.');
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
    final suffix = thumbnail ? 'thumb.webp' : extension;
    final path = '/memory/${book.hash}/$sceneId.v$generationVersion.$suffix';
    images[path] = bytes;
    return path;
  }

  @override
  Future<void> saveManifest(
    CatalogBook book,
    IllustrationManifest manifest,
  ) async {
    manifests[book.hash] = manifest;
  }
}
