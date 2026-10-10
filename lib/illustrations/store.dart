// The persistence lifecycle is documented on IllustrationStore and its file implementation.
// ignore_for_file: public_member_api_docs

import 'dart:typed_data';

import '../catalog/catalog_book.dart';
import 'book_text_index.dart';
import 'illustration_manifest.dart';

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
