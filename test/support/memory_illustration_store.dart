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

  @override
  Future<void> deleteSceneFiles(CatalogBook book, String sceneId) async {
    images.remove('$sceneId:image');
    images.remove('$sceneId:thumbnail');
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
    bool thumbnail = false,
  }) async {
    final key = '$sceneId:${thumbnail ? 'thumbnail' : 'image'}';
    images[key] = bytes;
    return '/memory/$key.webp';
  }

  @override
  Future<void> saveManifest(
    CatalogBook book,
    IllustrationManifest manifest,
  ) async {
    manifests[book.hash] = manifest;
  }
}
