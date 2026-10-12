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

  /// Saves one native-MIME asset to a scene/version-owned path. A derived
  /// thumbnail must be WebP; an original preview aliases the original save.
  /// This does not commit the version: save all assets, then the manifest.
  Future<String> saveImage(
    CatalogBook book,
    String sceneId,
    Uint8List bytes, {
    required String mimeType,
    required int generationVersion,
    bool thumbnail,
  });

  /// Deletes only validated files belonging to this scene, never stored paths.
  /// After replacement manifest commit, pass the obsolete version; otherwise
  /// omit it to remove every owned version during scene/book privacy cleanup.
  Future<void> deleteSceneFiles(
    CatalogBook book,
    String sceneId, {
    int? generationVersion,
  });
}
