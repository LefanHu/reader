import 'package:flutter/foundation.dart';

import '../catalog/catalog_book.dart';
import '../text/text_position.dart';
import 'api.dart';
import 'book_text_index.dart';
import 'gate.dart';
import 'illustration_exception.dart';
import 'illustration_manifest.dart';
import 'illustration_profile.dart';
import 'illustration_scene.dart';
import 'illustration_setup.dart';
import 'indexer.dart';
import 'outbox.dart';
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

  /// Durable book-deletion receipts outside source-book directories.
  final IllustrationDeletionOutbox deletionOutbox;

  /// Evaluates scene anchors before any unlock request.
  final IllustrationGate gate;

  /// Authoritative loaded and lazily created book manifests.
  final Map<String, IllustrationManifest> manifests = {};

  /// Whether consent setup is currently active.
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
        await deletionOutbox.enqueue(cloudBookId);
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
      for (final scene in manifestFor(book).scenes) {
        await store.deleteSceneFiles(book, scene.id);
      }
      final manifest = IllustrationManifest(bookHash: book.hash);
      manifests[book.hash] = manifest;
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

  /// Builds the local index and registers metadata before showing consent.
  ///
  /// No chapter prose is uploaded until [confirm] is called.
  Future<IllustrationSetup> beginSetup(CatalogBook book) async {
    busy = true;
    error = null;
    _changed();
    try {
      final index = await _indexFor(book);
      await api.signIn();
      await _refreshCloudAccount();
      await drainDeletions();
      // Reimported bytes produce the same cloud identity. Finish old deletions
      // before registration so a delayed retry cannot delete the new profile.
      if ((await deletionOutbox.load()).isNotEmpty) {
        throw const IllustrationException(
          'Cloud cleanup is pending. Try enabling illustrations again when connected.',
        );
      }
      return await api.registerBook(book, chapterCount: index.chapters.length);
    } on Object catch (failure) {
      error = failure.toString();
      rethrow;
    } finally {
      busy = false;
      _changed();
    }
  }

  /// Persists consent and begins current/next chapter generation.
  Future<void> confirm(
    CatalogBook book, {
    required IllustrationSetup setup,
    required String style,
    int density = 3,
  }) async {
    final profile = IllustrationProfile(
      enabled: true,
      style: style,
      density: density,
      styleVersion: 1,
      cloudBookId: setup.cloudBookId,
    );
    await api.confirmProfile(profile);
    final manifest = manifestFor(book).copyWith(profile: profile);
    manifests[book.hash] = manifest;
    await store.saveManifest(book, manifest);
    _changed();
    await _scheduleAhead(
      book,
      manifest,
      await _indexFor(book),
      book.lastPosition,
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
    await api.regenerateScene(scene.id);
    await _updateScene(
      book,
      scene.copyWith(state: IllustrationSceneState.generating),
    );
    _lastIllustrationRefresh.remove(book.hash);
    _changed();
  }

  /// Polls auxiliary work while the reader is idle on a stable text position.
  Future<void> refresh(CatalogBook book) async {
    final current = _currentBook(book);
    final raw = current?.lastPosition ?? book.lastPosition;
    if (raw == null) return;
    await advance(book, raw);
  }

  /// Removes one local and cloud scene without modifying the source book.
  Future<void> deleteScene(CatalogBook book, IllustrationScene scene) async {
    try {
      await api.deleteScene(scene.id);
    } on Object {
      // Local privacy remains available when cloud deletion cannot connect.
    }
    await store.deleteSceneFiles(book, scene.id);
    final manifest = manifestFor(book).copyWith(
      scenes: manifestFor(book).scenes
          .where((item) => item.id != scene.id)
          .toList(),
    );
    manifests[book.hash] = manifest;
    await store.saveManifest(book, manifest);
    _changed();
  }

  Future<void>? _deletionDrain;

  /// Retries durable book deletions once using only an existing cloud session.
  Future<void> drainDeletions() => _deletionDrain ??= _performDeletionDrain()
      .whenComplete(() => _deletionDrain = null);

  Future<void> _performDeletionDrain() async {
    try {
      final pendingDeletions = await deletionOutbox.load();
      if (pendingDeletions.isEmpty ||
          !api.configured ||
          !await api.hasSession()) {
        return;
      }
      for (final pending in pendingDeletions) {
        try {
          await api.deleteBook(pending.cloudBookId, interactive: false);
          await deletionOutbox.remove(pending.cloudBookId);
        } on Object {
          // Leave requests durable while connectivity or identity is unavailable.
        }
      }
    } on Object {
      // Startup privacy retries are auxiliary and must never block offline reading.
    }
  }

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
    if (profile == null || !profile.enabled) return;
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
      manifests[book.hash] = updated;
      await store.saveManifest(book, updated);
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
      await _scheduleAhead(book, manifestFor(book), index, position);
      final lastRefresh = _lastIllustrationRefresh[book.hash];
      if (lastRefresh == null ||
          DateTime.now().difference(lastRefresh) >
              const Duration(seconds: 15)) {
        await _refreshIllustrationJobs(book);
        _lastIllustrationRefresh[book.hash] = DateTime.now();
      }
      for (final scene in List.of(manifestFor(book).scenes)) {
        if (scene.state != IllustrationSceneState.readyLocked ||
            !gate.hasPassed(
              anchor: scene.anchor,
              index: index,
              position: position,
            )) {
          continue;
        }
        final released = await api.unlockScene(scene.id);
        final imagePath = await store.saveImage(book, scene.id, released.image);
        final thumbnailPath = await store.saveImage(
          book,
          scene.id,
          released.thumbnail,
          thumbnail: true,
        );
        await _updateScene(
          book,
          scene.copyWith(
            state: IllustrationSceneState.unlocked,
            localImagePath: imagePath,
            localThumbnailPath: thumbnailPath,
            altText: released.altText,
            caption: released.caption,
            generationVersion: released.generationVersion,
          ),
        );
      }
    } on Object catch (failure) {
      // Illustration failures are auxiliary and must never interrupt reading.
      error = failure.toString();
      _changed();
    } finally {
      _advancingIllustrations.remove(book.hash);
    }
  }

  Future<void> _refreshIllustrationJobs(CatalogBook book) async {
    final scenes = List<IllustrationScene>.of(manifestFor(book).scenes);
    for (final jobId in manifestFor(book).chapterJobs.values) {
      final result = await api.getJob(jobId);
      for (final incoming in result.scenes) {
        final index = scenes.indexWhere((scene) => scene.id == incoming.id);
        if (index < 0) {
          scenes.add(incoming);
        } else if (!scenes[index].available) {
          scenes[index] = incoming;
        }
      }
    }
    final manifest = manifestFor(book).copyWith(scenes: scenes);
    manifests[book.hash] = manifest;
    await store.saveManifest(book, manifest);
    _changed();
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
    manifests[book.hash] = manifest;
    await store.saveManifest(book, manifest);
    _changed();
  }
}
