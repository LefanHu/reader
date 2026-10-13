import 'package:flutter/foundation.dart';

import '../catalog/catalog_book.dart';
import 'api.dart';
import 'illustration_book_text.dart';
import 'illustration_exception.dart';
import 'illustration_manifest.dart';
import 'illustration_scene.dart';
import 'store.dart';

/// Downloads released scene art and commits it into the coordinator-owned
/// manifests.
///
/// Ownership protocol: image and thumbnail are saved to generation-owned
/// paths first, then one manifest write commits them. Files of a generation
/// that lost to deletion, disabling or a competing commit are removed; old
/// generation files are removed only after the replacement manifest commits.
class IllustrationArtCommitter {
  /// Borrows the coordinator's authoritative [manifests] map.
  IllustrationArtCommitter({
    required this.api,
    required this.store,
    required this.manifests,
    required this.currentBook,
    required this.changed,
  });

  /// Cloud unlock boundary returning released art.
  final IllustrationApi api;

  /// Persists art files and manifests.
  final IllustrationStore store;

  /// Authoritative manifests owned by the illustration coordinator.
  final Map<String, IllustrationManifest> manifests;

  /// The live catalog entry for a book, or null once it was deleted.
  final CatalogBook? Function(CatalogBook) currentBook;

  /// Publishes a committed manifest change.
  final VoidCallback changed;

  /// Downloads every ready or pending-replacement scene of [book] whose anchor
  /// resolves in [text]; unresolved anchors never download.
  Future<void> downloadReady(
    CatalogBook book,
    IllustrationBookText text,
  ) async {
    for (final scene in List.of(manifests[book.hash]?.scenes ?? const [])) {
      if ((scene.state != IllustrationSceneState.readyLocked &&
              scene.pendingGeneration == null) ||
          !await text.resolves(scene.anchor)) {
        continue;
      }
      final released = await api.unlockScene(scene.id);
      if (released.generation < scene.generation ||
          (scene.localImagePath != null &&
              released.generation == scene.generation) ||
          (scene.pendingGeneration != null &&
              released.generation < scene.pendingGeneration!)) {
        throw const IllustrationException(
          'The replacement illustration is not ready. Try again when connected.',
        );
      }
      if (_replacementScene(book, scene, released.generation) == null) {
        await _discardUncommitted(book, scene.id, released.generation);
        continue;
      }
      final imagePath = await store.saveImage(
        book,
        scene.id,
        released.image,
        mimeType: released.imageMimeType,
        generation: released.generation,
      );
      final thumbnailPath = released.thumbnailUsesOriginal
          ? imagePath
          : await store.saveImage(
              book,
              scene.id,
              released.thumbnail,
              mimeType: released.thumbnailMimeType,
              generation: released.generation,
              thumbnail: true,
            );
      final latest = _replacementScene(book, scene, released.generation);
      if (latest == null) {
        await _discardUncommitted(book, scene.id, released.generation);
        continue;
      }
      final committed = await _commit(
        book,
        scene,
        latest.copyWith(
          state: latest.available
              ? latest.state
              : IllustrationSceneState.unlocked,
          localImagePath: imagePath,
          localThumbnailPath: thumbnailPath,
          altText: released.altText,
          caption: released.caption,
          generation: released.generation,
          regenerating: false,
          pendingGeneration: null,
          failureCategory: null,
        ),
      );
      if (!committed) {
        await _discardUncommitted(book, scene.id, released.generation);
        continue;
      }
      // Only a committed manifest transfers ownership away from old files.
      if (scene.localImagePath != null &&
          scene.generation != released.generation) {
        await store.deleteSceneFiles(
          book,
          scene.id,
          generation: scene.generation,
        );
      }
    }
  }

  IllustrationScene? _replacementScene(
    CatalogBook book,
    IllustrationScene original,
    int targetGeneration,
  ) {
    final manifest = manifests[book.hash];
    if (currentBook(book) == null || manifest?.enabled != true) return null;
    final latest = manifest!.scenes
        .where((scene) => scene.id == original.id)
        .firstOrNull;
    if (latest == null ||
        latest.jobId != original.jobId ||
        latest.anchor.href != original.anchor.href ||
        latest.anchor.spineOrdinal != original.anchor.spineOrdinal ||
        latest.anchor.paragraphId != original.anchor.paragraphId ||
        latest.generation > targetGeneration ||
        (latest.localImagePath != null &&
            latest.generation == targetGeneration) ||
        (latest.pendingGeneration ?? 0) > targetGeneration) {
      return null;
    }
    return latest;
  }

  Future<bool> _commit(
    CatalogBook book,
    IllustrationScene original,
    IllustrationScene replacement,
  ) async {
    var wroteCandidate = false;
    while (true) {
      final latest = _replacementScene(book, original, replacement.generation);
      final snapshot = manifests[book.hash];
      if (latest == null || snapshot == null) {
        // If deletion/disable won while writing, restore its authoritative record.
        if (wroteCandidate && snapshot != null && currentBook(book) != null) {
          await store.saveManifest(book, snapshot);
        }
        return false;
      }
      final updated = replacement.copyWith(
        state: latest.available
            ? latest.state
            : IllustrationSceneState.unlocked,
      );
      final manifest = snapshot.copyWith(
        scenes: snapshot.scenes
            .map((scene) => scene.id == updated.id ? updated : scene)
            .toList(),
      );
      await store.saveManifest(book, manifest);
      wroteCandidate = true;
      if (!identical(manifests[book.hash], snapshot) ||
          currentBook(book) == null) {
        continue;
      }
      manifests[book.hash] = manifest;
      changed();
      return true;
    }
  }

  Future<void> _discardUncommitted(
    CatalogBook book,
    String sceneId,
    int generation,
  ) async {
    final current = manifests[book.hash]?.scenes
        .where((scene) => scene.id == sceneId)
        .firstOrNull;
    // A competing local commit owns these files even if this completion is stale.
    if (current?.localImagePath != null && current!.generation == generation) {
      return;
    }
    await store.deleteSceneFiles(book, sceneId, generation: generation);
  }
}
