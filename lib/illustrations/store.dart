// The persistence lifecycle is documented on IllustrationStore and its file implementation.
// ignore_for_file: public_member_api_docs

import 'dart:typed_data';

import '../catalog/catalog_book.dart';
import 'illustration_manifest.dart';

/// Atomic persistence boundary for illustration manifests and art.
abstract interface class IllustrationStore {
  Future<IllustrationManifest> loadManifest(CatalogBook book);
  Future<void> saveManifest(CatalogBook book, IllustrationManifest manifest);

  /// Saves one native-MIME asset to a scene/generation-owned path. A derived
  /// thumbnail must be WebP; an original preview aliases the original save.
  /// This does not commit the generation: save all assets, then the manifest.
  Future<String> saveImage(
    CatalogBook book,
    String sceneId,
    Uint8List bytes, {
    required String mimeType,
    required int generation,
    bool thumbnail,
  });

  /// Deletes only validated files belonging to this scene, never stored paths.
  /// After replacement manifest commit, pass the obsolete generation; otherwise
  /// omit it to remove every owned generation during scene/book privacy cleanup.
  Future<void> deleteSceneFiles(
    CatalogBook book,
    String sceneId, {
    int? generation,
  });
}
