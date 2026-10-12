import 'package:flutter/foundation.dart';

import '../catalog/catalog_book.dart';
import '../cloud_deletion_outbox.dart';
import '../cloud_deletion_queue.dart';
import '../identity/cloud_identity.dart';
import '../identity/cloud_identity_exception.dart';
import '../identity/cloud_service_exception.dart';
import '../text/text_position.dart';
import 'api.dart';
import 'book_text_index.dart';
import 'gate.dart';
import 'illustration_exception.dart';
import 'illustration_manifest.dart';
import 'illustration_profile.dart';
import 'illustration_scene.dart';
import 'illustration_selection.dart';
import 'illustration_setup.dart';
import 'indexer.dart';
import 'store.dart';

/// Owns illustration sidecars, indexing, spoiler gates, and cloud job workflows.
///
/// Dependencies and live catalog/narration callbacks are installed once. Changes
/// publish through the application notifier; this owner introduces no additional
/// cancellation or disposal fences around existing in-flight feature work.
class IllustrationCoordinator {
  /// Installs feature services and live cross-feature callbacks.
  IllustrationCoordinator({
    required this.store,
    required this.textIndexer,
    required this.api,
    required this.identity,
    required this.deletionOutbox,
    required this.gate,
    required this._currentBook,
    required this._narrationOwnsPosition,
    required this._refreshCloudAccount,
    required this._changed,
  });

  /// Persists indexes, manifests, and downloaded scene files.
  final IllustrationStore store;

  /// Builds normalized chapter indexes for scheduling and spoiler evaluation.
  final TextIndexer textIndexer;

  /// Cloud registration, generation, unlock, and privacy boundary.
  final IllustrationApi api;

  /// Shared account session used for sign-in and existing-session probes.
  final CloudIdentity identity;

  /// Durable book-deletion receipts outside source-book directories.
  final CloudDeletionOutbox deletionOutbox;

  late final _deletions = CloudDeletionQueue(
    outbox: deletionOutbox,
    ready: () async => api.configured && await identity.hasSession(),
    delete: (id) => api.deleteBook(id, interactive: false),
  );

  /// Evaluates scene anchors before any unlock request.
  final IllustrationGate gate;

  /// Authoritative loaded and lazily created book manifests.
  final Map<String, IllustrationManifest> manifests = {};

  /// Whether setup, consent confirmation, or a settings save is active.
  bool busy = false;

  /// Latest auxiliary illustration failure presented to the reader.
  String? error;

  final CatalogBook? Function(CatalogBook) _currentBook;
  final bool Function(CatalogBook) _narrationOwnsPosition;
  final Future<void> Function() _refreshCloudAccount;
  final VoidCallback _changed;
  final Map<String, BookTextIndex> _textIndexes = {};
  final Set<String> _advancingIllustrations = {};
  final Map<String, DateTime> _lastIllustrationRefresh = {};

  // A future ID remains readable in the manifest, but this client cannot admit
  // generation for a source it does not support. Existing art/jobs still load.
  static const _supportedProviderIds = {
    'openai',
    'google',
    'seedream',
    'qwen',
    'xai',
    'flux',
    'diagnostic',
  };

  /// Restores book sidecars without publishing a startup notification.
  Future<void> loadManifests(List<CatalogBook> books) async {
    final loaded = await Future.wait(books.map(store.loadManifest));
    manifests
      ..clear()
      ..addEntries(
        loaded.map((manifest) => MapEntry(manifest.bookHash, manifest)),
      );
  }

  /// Deletes an existing cloud profile or durably enqueues its failed deletion.
  ///
  /// Reads only an existing manifest, never creating one during book deletion.
  Future<void> requestBookDeletion(CatalogBook book) async {
    final cloudBookId = manifests[book.hash]?.profile?.cloudBookId;
    if (cloudBookId != null && cloudBookId.isNotEmpty) {
      try {
        await api.deleteBook(cloudBookId);
      } on Object {
        // Local privacy remains usable offline; the receipt outlives the book.
        await _deletions.enqueue(cloudBookId);
      }
    }
  }

  /// Removes only the book's in-memory manifest and normalized index.
  void forget(CatalogBook book) {
    manifests.remove(book.hash);
    _textIndexes.remove(book.hash);
  }

  /// Deletes local scenes and disables manifests while retaining books/indexes.
  Future<void> clearLocalAccountData(List<CatalogBook> books) async {
    for (final book in books) {
      final scenes = manifestFor(book).scenes;
      final manifest = IllustrationManifest(bookHash: book.hash);
      manifests[book.hash] = manifest;
      for (final scene in scenes) {
        await store.deleteSceneFiles(book, scene.id);
      }
      await store.saveManifest(book, manifest);
    }
  }

  /// Whether Firebase and the illustration API are configured for this build.
  bool get configured => api.configured;

  /// Returns [book]'s sidecar, creating a disabled in-memory value if absent.
  IllustrationManifest manifestFor(CatalogBook book) => manifests.putIfAbsent(
    book.hash,
    () => IllustrationManifest(bookHash: book.hash),
  );

  /// Signs in explicitly and drains deletions before read-only availability.
  ///
  /// Registration happens only when rollout and a source are available. No
  /// chapter prose is uploaded until [confirm] is called.
  Future<IllustrationSetup> beginSetup(CatalogBook book) async {
    if (busy) {
      throw const IllustrationException(
        'Illustration setup is already in progress.',
      );
    }
    busy = true;
    error = null;
    _changed();
    try {
      await identity.signIn();
      await _refreshCloudAccount();
      await drainDeletions();
      // Reimported bytes produce the same cloud identity. Finish old deletions
      // before registration so a delayed retry cannot delete the new profile.
      if (await _deletions.hasPending) {
        throw const IllustrationException(
          'Cloud cleanup is pending. Try enabling illustrations again when connected.',
        );
      }
      final configuration = await api.getConfiguration();
      if (!configuration.enabled || !configuration.hasAvailableProvider) {
        final current = manifestFor(book).profile;
        return IllustrationSetup(
          cloudBookId: null,
          suggestedStyle: current?.style ?? 'Cinematic storybook realism',
          alternativeStyles: const [],
          estimatedCredits: 0,
          configuration: configuration,
          currentProfile: current,
        );
      }
      final index = await _indexFor(book);
      return await api.registerBook(book, chapterCount: index.chapters.length);
    } on Object catch (failure) {
      final safe = _safeFailure(failure);
      error = safe.toString();
      throw safe;
    } finally {
      busy = false;
      _changed();
    }
  }

  /// Persists consent and begins current/next chapter generation.
  Future<void> confirm(
    CatalogBook book, {
    required IllustrationSetup setup,
    required IllustrationSelection selection,
    int density = 3,
  }) async {
    if (busy) return;
    busy = true;
    error = null;
    _changed();
    try {
      _requireSelection(setup, selection);
      final profile = await api.confirmProfile(
        IllustrationProfile(
          enabled: true,
          style: selection.style,
          density: density,
          providerId: selection.providerId,
          revision: setup.currentProfile?.revision ?? 0,
          analysisVersion: setup.currentProfile?.analysisVersion ?? 2,
          cloudBookId: setup.cloudBookId!,
        ),
      );
      final manifest = manifestFor(book).copyWith(profile: profile);
      await store.saveManifest(book, manifest);
      manifests[book.hash] = manifest;
      _changed();
      await _scheduleAhead(
        book,
        manifest,
        await _indexFor(book),
        book.lastPosition,
      );
    } on Object catch (failure) {
      final safe = _safeFailure(failure);
      error = safe.toString();
      throw safe;
    } finally {
      busy = false;
      _changed();
    }
  }

  /// Saves per-book settings without replacing admitted jobs, scenes or files.
  ///
  /// The setup's authoritative revision fences stale edits. A matching server
  /// response performs no local save or scheduling; retries after a lost
  /// response still recover its authoritative revision.
  Future<void> updateSettings(
    CatalogBook book, {
    required IllustrationSetup setup,
    required IllustrationSelection selection,
  }) async {
    if (busy) return;
    busy = true;
    error = null;
    _changed();
    try {
      _requireSelection(setup, selection);
      final current = manifestFor(book).profile;
      if (current == null || current.cloudBookId != setup.cloudBookId) {
        throw const IllustrationException(
          'Reopen Illustration settings before saving changes.',
        );
      }
      final response = await api.confirmProfile(
        IllustrationProfile(
          enabled: current.enabled,
          style: selection.style,
          density: current.density,
          providerId: selection.providerId,
          revision: setup.currentProfile?.revision ?? 0,
          analysisVersion: current.analysisVersion,
          cloudBookId: current.cloudBookId,
        ),
      );
      final saved = IllustrationProfile(
        enabled: current.enabled,
        style: response.style,
        density: response.density,
        providerId: response.providerId,
        revision: response.revision,
        analysisVersion: response.analysisVersion,
        cloudBookId: current.cloudBookId,
      );
      if (_sameProfile(current, saved)) return;
      final manifest = manifestFor(book).copyWith(profile: saved);
      await store.saveManifest(book, manifest);
      manifests[book.hash] = manifest;
      _changed();
      await _scheduleAhead(
        book,
        manifest,
        await _indexFor(book),
        book.lastPosition,
      );
    } on Object catch (failure) {
      final safe = _safeFailure(failure);
      error = safe.toString();
      throw safe;
    } finally {
      busy = false;
      _changed();
    }
  }

  void _requireSelection(
    IllustrationSetup setup,
    IllustrationSelection selection,
  ) {
    if (setup.cloudBookId == null ||
        !setup.configuration.enabled ||
        !_supportedProviderIds.contains(selection.providerId) ||
        !setup.configuration.providers.any(
          (option) => option.id == selection.providerId && option.available,
        )) {
      throw const IllustrationException(
        'This illustration source is unavailable. Reopen Illustration settings to choose an available source.',
      );
    }
  }

  bool _sameProfile(IllustrationProfile first, IllustrationProfile second) =>
      first.enabled == second.enabled &&
      first.cloudBookId == second.cloudBookId &&
      first.providerId == second.providerId &&
      first.style == second.style &&
      first.density == second.density &&
      first.analysisVersion == second.analysisVersion &&
      first.revision == second.revision;

  Object _safeFailure(Object failure) {
    if (failure is CloudServiceException && failure.statusCode == 409) {
      return const IllustrationException(
        'Illustration settings changed on another device. Reopen Illustration settings and try again.',
      );
    }
    if (failure is IllustrationException ||
        failure is CloudIdentityException ||
        failure is CloudServiceException) {
      return failure;
    }
    return const IllustrationException(
      'Illustrations could not be updated. Check your connection and try again.',
    );
  }

  /// First downloaded scene that has not yet interrupted the reader.
  IllustrationScene? pendingRevealFor(CatalogBook book) {
    if (_narrationOwnsPosition(book)) return null;
    for (final scene in manifestFor(book).scenes) {
      if (scene.state == IllustrationSceneState.unlocked &&
          !scene.automaticRevealDismissed &&
          scene.localImagePath != null) {
        return scene;
      }
    }
    return null;
  }

  /// Prevents a cinematic scene from presenting automatically more than once.
  Future<void> markRevealed(CatalogBook book, IllustrationScene scene) =>
      _updateScene(book, scene.copyWith(automaticRevealDismissed: true));

  /// Retains a scene locally but suppresses future automatic presentation.
  Future<void> hide(CatalogBook book, IllustrationScene scene) => _updateScene(
    book,
    scene.copyWith(
      state: IllustrationSceneState.hidden,
      automaticRevealDismissed: true,
    ),
  );

  /// Requests a one-credit replacement while retaining the current image.
  Future<void> regenerate(CatalogBook book, IllustrationScene scene) async {
    try {
      final profile = manifestFor(book).profile;
      if (profile == null ||
          !profile.enabled ||
          !_supportedProviderIds.contains(profile.providerId)) {
        throw const IllustrationException(
          'Choose an available source in Illustration settings before generating new artwork.',
        );
      }
      await api.regenerateScene(scene.id);
      await _updateScene(
        book,
        (manifestFor(book).scenes.firstWhere(
          (item) => item.id == scene.id,
          orElse: () => scene,
        )).copyWith(
          regenerating: true,
          pendingGenerationVersion: null,
          failureCategory: null,
        ),
      );
      _lastIllustrationRefresh.remove(book.hash);
      _changed();
    } on Object catch (failure) {
      final safe = _safeFailure(failure);
      error = safe.toString();
      _changed();
      throw safe;
    }
  }

  /// Polls auxiliary work while the reader is idle on a stable text position.
  Future<void> refresh(CatalogBook book) async {
    if (busy || _narrationOwnsPosition(book)) return;
    final current = _currentBook(book);
    final raw = current?.lastPosition ?? book.lastPosition;
    if (raw == null) return;
    await advance(book, raw);
  }

  /// Removes one local and cloud scene without modifying the source book.
  Future<void> deleteScene(CatalogBook book, IllustrationScene scene) async {
    // Local privacy owns removal immediately, before any cloud or file await.
    final remaining = manifestFor(book).copyWith(
      scenes: manifestFor(book).scenes
          .where((item) => item.id != scene.id)
          .toList(),
    );
    manifests[book.hash] = remaining;
    _changed();
    try {
      await api.deleteScene(scene.id);
    } on Object {
      // Local privacy remains available when cloud deletion cannot connect.
    }
    await store.deleteSceneFiles(book, scene.id);
    final manifest = manifestFor(book);
    await store.saveManifest(book, manifest);
    _changed();
  }

  /// Retries durable book deletions once using only an existing cloud session.
  Future<void> drainDeletions() => _deletions.drain();

  Future<BookTextIndex> _indexFor(CatalogBook book) async {
    final memory = _textIndexes[book.hash];
    if (memory != null) return memory;
    final stored = await store.loadIndex(book);
    if (stored != null) {
      _textIndexes[book.hash] = stored;
      return stored;
    }
    final created = await textIndexer.index(
      sourcePath: book.path,
      bookHash: book.hash,
    );
    _textIndexes[book.hash] = created;
    await store.saveIndex(book, created);
    return created;
  }

  Future<void> _scheduleAhead(
    CatalogBook book,
    IllustrationManifest manifest,
    BookTextIndex index,
    TextPosition? position,
  ) async {
    final profile = manifest.profile;
    if (profile == null ||
        !profile.enabled ||
        !_supportedProviderIds.contains(profile.providerId)) {
      return;
    }
    final href = position?.sectionId;
    final current = href == null
        ? index.chapters.first
        : index.chapterForHref(href);
    final start = current?.spineOrdinal ?? 0;
    final jobs = Map<int, String>.of(manifest.chapterJobs);
    for (final ordinal in [start, start + 1]) {
      if (ordinal >= index.chapters.length || jobs.containsKey(ordinal)) {
        continue;
      }
      final id = await api.createChapterJob(
        profile: profile,
        chapter: index.chapters[ordinal],
      );
      jobs[ordinal] = id;
      final updated = manifestFor(book).copyWith(chapterJobs: jobs);
      await store.saveManifest(book, updated);
      manifests[book.hash] = updated;
    }
    _changed();
  }

  /// Schedules nearby chapters, refreshes jobs, and unlocks only passed gates.
  ///
  /// Both image and thumbnail are committed before a scene becomes unlocked.
  Future<void> advance(CatalogBook book, TextPosition position) async {
    if (_advancingIllustrations.contains(book.hash) ||
        !manifestFor(book).enabled) {
      return;
    }
    _advancingIllustrations.add(book.hash);
    try {
      final index = await _indexFor(book);
      if (!busy) {
        await _scheduleAhead(book, manifestFor(book), index, position);
      }
      final lastRefresh = _lastIllustrationRefresh[book.hash];
      if (lastRefresh == null ||
          DateTime.now().difference(lastRefresh) >
              const Duration(seconds: 15)) {
        await _refreshIllustrationJobs(book);
        _lastIllustrationRefresh[book.hash] = DateTime.now();
      }
      for (final scene in List.of(manifestFor(book).scenes)) {
        if ((scene.state != IllustrationSceneState.readyLocked &&
                scene.pendingGenerationVersion == null) ||
            !gate.hasPassed(
              anchor: scene.anchor,
              index: index,
              position: position,
            )) {
          continue;
        }
        final released = await api.unlockScene(scene.id);
        if (released.generationVersion < scene.generationVersion ||
            (scene.localImagePath != null &&
                released.generationVersion == scene.generationVersion) ||
            (scene.pendingGenerationVersion != null &&
                released.generationVersion < scene.pendingGenerationVersion!)) {
          throw const IllustrationException(
            'The replacement illustration is not ready. Try again when connected.',
          );
        }
        if (_replacementScene(book, scene, released.generationVersion) ==
            null) {
          await _discardUncommittedVersion(
            book,
            scene.id,
            released.generationVersion,
          );
          continue;
        }
        final imagePath = await store.saveImage(
          book,
          scene.id,
          released.image,
          mimeType: released.imageMimeType,
          generationVersion: released.generationVersion,
        );
        final thumbnailPath = released.thumbnailUsesOriginal
            ? imagePath
            : await store.saveImage(
                book,
                scene.id,
                released.thumbnail,
                mimeType: released.thumbnailMimeType,
                generationVersion: released.generationVersion,
                thumbnail: true,
              );
        final latest = _replacementScene(
          book,
          scene,
          released.generationVersion,
        );
        if (latest == null) {
          await _discardUncommittedVersion(
            book,
            scene.id,
            released.generationVersion,
          );
          continue;
        }
        final committed = await _commitReplacement(
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
            generationVersion: released.generationVersion,
            regenerating: false,
            pendingGenerationVersion: null,
            failureCategory: null,
          ),
        );
        if (!committed) {
          await _discardUncommittedVersion(
            book,
            scene.id,
            released.generationVersion,
          );
          continue;
        }
        // Only a committed manifest transfers ownership away from old files.
        if (scene.localImagePath != null &&
            scene.generationVersion != released.generationVersion) {
          await store.deleteSceneFiles(
            book,
            scene.id,
            generationVersion: scene.generationVersion,
          );
        }
      }
    } on Object catch (failure) {
      // Illustration failures are auxiliary and must never interrupt reading.
      error = _safeFailure(failure).toString();
      _changed();
    } finally {
      _advancingIllustrations.remove(book.hash);
    }
  }

  IllustrationScene? _replacementScene(
    CatalogBook book,
    IllustrationScene original,
    int targetVersion,
  ) {
    final manifest = manifests[book.hash];
    if (_currentBook(book) == null || manifest?.enabled != true) return null;
    final latest = manifest!.scenes
        .where((scene) => scene.id == original.id)
        .firstOrNull;
    if (latest == null ||
        latest.jobId != original.jobId ||
        latest.anchor.href != original.anchor.href ||
        latest.anchor.spineOrdinal != original.anchor.spineOrdinal ||
        latest.anchor.paragraphId != original.anchor.paragraphId ||
        latest.generationVersion > targetVersion ||
        (latest.localImagePath != null &&
            latest.generationVersion == targetVersion) ||
        (latest.pendingGenerationVersion ?? 0) > targetVersion) {
      return null;
    }
    return latest;
  }

  Future<bool> _commitReplacement(
    CatalogBook book,
    IllustrationScene original,
    IllustrationScene replacement,
  ) async {
    var wroteCandidate = false;
    while (true) {
      final latest = _replacementScene(
        book,
        original,
        replacement.generationVersion,
      );
      final snapshot = manifests[book.hash];
      if (latest == null || snapshot == null) {
        // If deletion/disable won while writing, restore its authoritative record.
        if (wroteCandidate && snapshot != null && _currentBook(book) != null) {
          await store.saveManifest(book, snapshot);
        }
        return false;
      }
      final updated = replacement.copyWith(
        state: latest.available
            ? latest.state
            : IllustrationSceneState.unlocked,
        automaticRevealDismissed: latest.automaticRevealDismissed,
      );
      final manifest = snapshot.copyWith(
        scenes: snapshot.scenes
            .map((scene) => scene.id == updated.id ? updated : scene)
            .toList(),
      );
      await store.saveManifest(book, manifest);
      wroteCandidate = true;
      if (!identical(manifests[book.hash], snapshot) ||
          _currentBook(book) == null) {
        continue;
      }
      manifests[book.hash] = manifest;
      _changed();
      return true;
    }
  }

  Future<void> _discardUncommittedVersion(
    CatalogBook book,
    String sceneId,
    int generationVersion,
  ) async {
    final current = manifests[book.hash]?.scenes
        .where((scene) => scene.id == sceneId)
        .firstOrNull;
    // A competing local commit owns these files even if this completion is stale.
    if (current?.localImagePath != null &&
        current!.generationVersion == generationVersion) {
      return;
    }
    await store.deleteSceneFiles(
      book,
      sceneId,
      generationVersion: generationVersion,
    );
  }

  Future<void> _refreshIllustrationJobs(CatalogBook book) async {
    final beforePolling = manifests[book.hash];
    if (beforePolling?.enabled != true || _currentBook(book) == null) return;
    final incomingScenes = <IllustrationScene>[];
    for (final jobId in beforePolling!.chapterJobs.values) {
      final result = await api.getJob(jobId);
      incomingScenes.addAll(result.scenes);
    }
    // Polling awaits network IO; merge into the newest local reveal/path state.
    final current = manifests[book.hash];
    if (current?.enabled != true || _currentBook(book) == null) return;
    final scenes = List<IllustrationScene>.of(current!.scenes);
    for (final incoming in incomingScenes) {
      final index = scenes.indexWhere((scene) => scene.id == incoming.id);
      if (index < 0) {
        if (beforePolling.scenes.any((scene) => scene.id == incoming.id)) {
          continue; // Removed locally while this poll was awaiting network IO.
        }
        scenes.add(incoming);
      } else {
        scenes[index] = _mergeScene(scenes[index], incoming);
      }
    }
    final manifest = current.copyWith(scenes: scenes);
    await store.saveManifest(book, manifest);
    manifests[book.hash] = manifest;
    _changed();
  }

  IllustrationScene _mergeScene(
    IllustrationScene committed,
    IllustrationScene incoming,
  ) {
    if (incoming.generationVersion < committed.generationVersion) {
      return committed;
    }
    final generating =
        incoming.regenerating ||
        incoming.state == IllustrationSceneState.generating ||
        incoming.state == IllustrationSceneState.queued;
    final ready = incoming.state == IllustrationSceneState.readyLocked;
    if (committed.localImagePath == null) {
      return committed.copyWith(
        state: incoming.state,
        generationVersion: incoming.generationVersion,
        regenerating: generating,
        pendingGenerationVersion: null,
        failureCategory: incoming.failureCategory,
      );
    }
    if (generating) {
      return committed.copyWith(
        regenerating: true,
        pendingGenerationVersion: null,
        failureCategory: null,
      );
    }
    if (ready && incoming.generationVersion > committed.generationVersion) {
      return committed.copyWith(
        regenerating: false,
        pendingGenerationVersion:
            (committed.pendingGenerationVersion ?? 0) >
                incoming.generationVersion
            ? committed.pendingGenerationVersion
            : incoming.generationVersion,
        failureCategory: null,
      );
    }
    final failed =
        incoming.failureCategory != null ||
        incoming.state == IllustrationSceneState.failed ||
        incoming.state == IllustrationSceneState.skippedSafety;
    if (failed) {
      error =
          'The replacement illustration could not be completed. '
          'Your previous artwork is still available.';
    }
    if (!failed && ready && committed.pendingGenerationVersion != null) {
      // An older ready poll cannot discard a replacement already seen locally.
      return committed.copyWith(regenerating: false, failureCategory: null);
    }
    return committed.copyWith(
      regenerating: false,
      pendingGenerationVersion: null,
      failureCategory: incoming.failureCategory,
    );
  }

  Future<void> _updateScene(CatalogBook book, IllustrationScene updated) async {
    final scenes = List<IllustrationScene>.of(manifestFor(book).scenes);
    final index = scenes.indexWhere((scene) => scene.id == updated.id);
    if (index < 0) {
      scenes.add(updated);
    } else {
      scenes[index] = updated;
    }
    final manifest = manifestFor(book).copyWith(scenes: scenes);
    await store.saveManifest(book, manifest);
    manifests[book.hash] = manifest;
    _changed();
  }
}
