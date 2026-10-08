// Public state and service members are documented at their owning type and
// behavioral methods; trivial injected-field accessors are intentionally terse.
// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'account/api.dart';

import 'package:flutter/material.dart';

import 'text/document.dart';
import 'text/word_count.dart';

import 'book_service.dart';
import 'illustrations/api.dart';
import 'illustrations/gate.dart';
import 'illustrations/indexer.dart';
import 'illustrations/models.dart';
import 'illustrations/outbox.dart';
import 'illustrations/store.dart';
import 'models.dart';
import 'storage.dart';
import 'cloud_identity.dart';
import 'narration/api.dart';
import 'narration/player.dart';
import 'narration/session.dart';
import 'narration/store.dart';
import 'narration/models.dart';

/// Owns session state and coordinates UI, persistence, normalized text, and art jobs.
///
/// This remains the app's only shared [ChangeNotifier]. Illustration services
/// are injected boundaries so reading and tests never depend on cloud plugins.
class ReaderController extends ChangeNotifier {
  ReaderController({
    required this.catalogStore,
    required this.settingsStore,
    required this.importer,
    required this.picker,
    IllustrationStore? illustrationStore,
    TextIndexer? textIndexer,
    BookWordCounter? wordCounter,
    IllustrationApi? illustrationApi,
    IllustrationDeletionOutbox? illustrationDeletionOutbox,
    NarrationApi? narrationApi,
    NarrationPlayer? narrationPlayer,
    NarrationStore? narrationStore,
    TextDocumentStore? narrationDocuments,
    IllustrationDeletionOutbox? narrationDeletionOutbox,
    this.cloudIdentity,
    this.accountApi,
    this.illustrationGate = const IllustrationGate(),
  }) : illustrationStore = illustrationStore ?? FileIllustrationStore(),
       textIndexer = textIndexer ?? DocumentTextIndexer(),
       wordCounter = wordCounter ?? FileBookWordCounter(),
       illustrationApi =
           illustrationApi ??
           HttpIllustrationApi(identity: FirebaseIllustrationIdentity()),
       illustrationDeletionOutbox =
           illustrationDeletionOutbox ?? MemoryIllustrationDeletionOutbox(),
       narrationDeletionOutbox =
           narrationDeletionOutbox ?? MemoryIllustrationDeletionOutbox() {
    if (narrationApi != null &&
        narrationPlayer != null &&
        narrationStore != null) {
      narration = NarrationSession(
        api: narrationApi,
        player: narrationPlayer,
        store: narrationStore,
        documents: narrationDocuments,
        preferences: () => settings,
        isBookAvailable: (candidate) => books.any(
          (book) =>
              book.hash == candidate.hash &&
              book.path == candidate.path &&
              book.addedAt == candidate.addedAt,
        ),
        abandonRegistration: (id) async {
          await this.narrationDeletionOutbox.enqueue(id);
          unawaited(drainNarrationDeletions());
        },
        changed: () {
          if (!_disposed) notifyListeners();
        },
        commit: (book, position, progress) =>
            savePosition(book, position, progress, fromNarration: true),
        currentPosition: (book) => books
            .where((item) => item.hash == book.hash)
            .firstOrNull
            ?.lastPosition,
      );
    }
  }

  /// App-lifetime narration; absent in offline/test dependency graphs.
  NarrationSession? narration;

  /// Shared account boundary works with core-only configuration and no API URL.
  final CloudIdentity? cloudIdentity;

  /// Read-only usage service; absent in offline or core-only dependency graphs.
  final AccountApi? accountApi;

  /// Latest server snapshot belongs only to the currently displayed account.
  AccountUsage? accountUsage;

  /// Prevents duplicate refresh actions without blocking local preferences.
  bool usageLoading = false;

  /// Safe display message; failed refreshes never substitute invented balances.
  String? usageError;

  /// Distinguishes offline, attestation, and service failures in Settings.
  AccountUsageFailureKind? usageFailure;

  int _usageEpoch = 0;
  Future<void> _preferenceTail = Future.value();
  int _pendingPreferences = 0;

  /// Restored account label; it is not used to authorize requests or gate reading.
  String? cloudEmail;

  /// Disables duplicate account actions while a native sign-in dialog is active.
  bool cloudAccountBusy = false;

  /// Narration deletion retries stay outside book directories and never sign in.
  final IllustrationDeletionOutbox narrationDeletionOutbox;

  final CatalogStore catalogStore;
  final SettingsStore settingsStore;
  final BookImporter importer;
  final BookPicker picker;
  final IllustrationStore illustrationStore;
  final TextIndexer textIndexer;

  /// Background normalized-text counting, independent of cloud indexing.
  final BookWordCounter wordCounter;
  final IllustrationApi illustrationApi;
  final IllustrationDeletionOutbox illustrationDeletionOutbox;
  final IllustrationGate illustrationGate;

  List<CatalogBook> books = [];
  ReaderSettings settings = const ReaderSettings();
  final Map<String, IllustrationManifest> illustrationManifests = {};
  final Map<String, BookTextIndex> _textIndexes = {};
  bool importing = false;
  bool illustrationBusy = false;
  String? illustrationError;
  int importDone = 0;
  int importTotal = 0;
  Timer? _positionSave;
  bool _disposed = false;
  final Set<String> _advancingIllustrations = {};
  final Map<String, DateTime> _lastIllustrationRefresh = {};

  /// Creates the production dependency graph and restores persisted state.
  static Future<ReaderController> create() async {
    final store = await FileCatalogStore.create();
    final identity = FirebaseCloudIdentity();
    final controller = ReaderController(
      cloudIdentity: identity,
      accountApi: HttpAccountApi(identity: identity),
      narrationApi: HttpNarrationApi(identity: identity),
      narrationPlayer: await NativeNarrationPlayer.create(),
      narrationStore: FileNarrationStore(store.root),
      narrationDeletionOutbox: FileIllustrationDeletionOutbox(
        store.root,
        fileName: 'narration-deletions.json',
      ),
      catalogStore: store,
      settingsStore: PreferenceSettingsStore(),
      importer: BookImporter(root: store.root),
      picker: NativeBookPicker(),
      illustrationDeletionOutbox: FileIllustrationDeletionOutbox(store.root),
    );
    await controller.initialize();
    return controller;
  }

  /// Loads catalog, preferences, and book sidecars at startup.
  Future<void> initialize() async {
    final loaded = await Future.wait<Object>([
      catalogStore.load(),
      settingsStore.load(),
    ]);
    books = loaded[0] as List<CatalogBook>;
    settings = loaded[1] as ReaderSettings;
    final manifests = await Future.wait(
      books.map(illustrationStore.loadManifest),
    );
    illustrationManifests
      ..clear()
      ..addEntries(
        manifests.map((manifest) => MapEntry(manifest.bookHash, manifest)),
      );
    unawaited(_drainDeletionOutbox());
    unawaited(drainNarrationDeletions());
    unawaited(_backfillWordCounts());
    unawaited(refreshCloudAccount());
    notifyListeners();
  }

  // Snapshot identities only: positions can change while counting. Re-read the
  // live record before merging, and never resurrect a deleted book or notify
  // after disposal. Failures remain missing and retry on the next startup.
  Future<void> _backfillWordCounts() async {
    for (final candidate in List<CatalogBook>.of(books)) {
      if (_disposed) return;
      if (candidate.wordCount != null) continue;
      try {
        final count = await wordCounter.count(candidate.path);
        if (_disposed) return;
        final current = books
            .where(
              (book) =>
                  book.addedAt == candidate.addedAt &&
                  book.hash == candidate.hash &&
                  book.path == candidate.path,
            )
            .firstOrNull;
        if (current == null || current.wordCount != null) continue;
        _replace(current.copyWith(wordCount: count));
        await catalogStore.save(books);
      } on Object {
        // An unreadable section must not stop other books or offline reading.
      }
    }
  }

  /// Most recently opened book, used by the Continue reading card.
  CatalogBook? get currentBook {
    final recent = books.where((book) => book.lastOpenedAt != null).toList()
      ..sort((a, b) => b.lastOpenedAt!.compareTo(a.lastOpenedAt!));
    return recent.firstOrNull;
  }

  /// Whether Firebase and the illustration API are configured for this build.
  bool get illustrationsConfigured => illustrationApi.configured;

  /// Returns [book]'s sidecar, creating a disabled in-memory value if absent.
  IllustrationManifest manifestFor(CatalogBook book) => illustrationManifests
      .putIfAbsent(book.hash, () => IllustrationManifest(bookHash: book.hash));

  /// Picks files and imports them serially.
  ///
  /// Serial staging bounds memory and avoids duplicate directory commits.
  Future<List<ImportResult>> pickAndImport() async {
    final candidates = await picker.pick();
    if (candidates.isEmpty) return [];
    importing = true;
    importDone = 0;
    importTotal = candidates.length;
    notifyListeners();
    final results = <ImportResult>[];
    try {
      final hashes = books.map((book) => book.hash).toSet();
      for (final candidate in candidates) {
        final imported = await importer.import(candidate, hashes);
        results.add(imported.result);
        if (imported.book != null) {
          books = [...books, imported.book!];
          hashes.add(imported.book!.hash);
          await catalogStore.save(books);
        }
        importDone++;
        notifyListeners();
      }
      return results;
    } finally {
      importing = false;
      notifyListeners();
    }
  }

  /// Records recent activity before navigation enters the reader.
  Future<void> markOpened(CatalogBook book) async {
    if (narration != null && narration!.book?.hash != book.hash) {
      await narration!.pause();
    }
    final current = books.where((item) => item.hash == book.hash).firstOrNull;
    if (current == null) return;
    _replace(current.copyWith(lastOpenedAt: DateTime.now()));
    await catalogStore.save(books);
  }

  /// Builds the local index and registers metadata before showing consent.
  ///
  /// No chapter prose is uploaded until [confirmIllustrations] is called.
  Future<IllustrationSetup> beginIllustrationSetup(CatalogBook book) async {
    illustrationBusy = true;
    illustrationError = null;
    notifyListeners();
    try {
      final index = await _indexFor(book);
      await illustrationApi.signIn();
      await refreshCloudAccount();
      await _drainDeletionOutbox();
      // Reimported bytes produce the same cloud identity. Finish old deletions
      // before registration so a delayed retry cannot delete the new profile.
      if ((await illustrationDeletionOutbox.load()).isNotEmpty) {
        throw const IllustrationException(
          'Cloud cleanup is pending. Try enabling illustrations again when connected.',
        );
      }
      return await illustrationApi.registerBook(
        book,
        chapterCount: index.chapters.length,
      );
    } on Object catch (error) {
      illustrationError = error.toString();
      rethrow;
    } finally {
      illustrationBusy = false;
      notifyListeners();
    }
  }

  /// Persists consent and begins current/next chapter generation.
  Future<void> confirmIllustrations(
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
    await illustrationApi.confirmProfile(profile);
    final manifest = manifestFor(book).copyWith(profile: profile);
    illustrationManifests[book.hash] = manifest;
    await illustrationStore.saveManifest(book, manifest);
    notifyListeners();
    await _scheduleAhead(
      book,
      manifest,
      await _indexFor(book),
      book.lastPosition,
    );
  }

  /// Updates the leading text position and evaluates spoiler gates asynchronously.
  Future<void> savePosition(
    CatalogBook book,
    TextPosition position,
    double progress, {
    bool fromNarration = false,
  }) async {
    if (!fromNarration && narration?.ownsPosition(book) == true) return;
    if (_disposed || !books.any((item) => item.hash == book.hash)) return;
    final current = books.firstWhere(
      (item) => item.hash == book.hash,
      orElse: () => book,
    );
    _replace(
      current.copyWith(
        lastPosition: position,
        progress: progress.clamp(0, 1),
        lastOpenedAt: DateTime.now(),
      ),
    );
    _positionSave?.cancel();
    if (fromNarration) {
      // Chunk completion must survive suspension before the next audio load;
      // a debounced catalog write could otherwise invalidate an accurate resume.
      await catalogStore.save(books);
    } else {
      _positionSave = Timer(const Duration(milliseconds: 500), () {
        catalogStore.save(books);
      });
    }
    unawaited(_advanceIllustrations(book, position));
  }

  /// First downloaded scene that has not yet interrupted the reader.
  IllustrationScene? pendingRevealFor(CatalogBook book) {
    if (narration?.ownsPosition(book) == true) return null;
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
  Future<void> markIllustrationRevealed(
    CatalogBook book,
    IllustrationScene scene,
  ) => _updateScene(book, scene.copyWith(automaticRevealDismissed: true));

  /// Retains a scene locally but suppresses future automatic presentation.
  Future<void> hideIllustration(CatalogBook book, IllustrationScene scene) =>
      _updateScene(
        book,
        scene.copyWith(
          state: IllustrationSceneState.hidden,
          automaticRevealDismissed: true,
        ),
      );

  /// Requests a one-credit replacement while retaining the current image.
  Future<void> regenerateIllustration(
    CatalogBook book,
    IllustrationScene scene,
  ) async {
    await illustrationApi.regenerateScene(scene.id);
    await _updateScene(
      book,
      scene.copyWith(state: IllustrationSceneState.generating),
    );
    _lastIllustrationRefresh.remove(book.hash);
    notifyListeners();
  }

  /// Polls auxiliary work while the reader is idle on a stable text position.
  Future<void> refreshIllustrations(CatalogBook book) async {
    final current = books.where((item) => item.hash == book.hash).firstOrNull;
    final raw = current?.lastPosition ?? book.lastPosition;
    if (raw == null) return;
    await _advanceIllustrations(book, raw);
  }

  /// Removes one local and cloud scene without modifying the source book.
  Future<void> deleteIllustration(
    CatalogBook book,
    IllustrationScene scene,
  ) async {
    try {
      await illustrationApi.deleteScene(scene.id);
    } on Object {
      // Local privacy remains available when cloud deletion cannot connect.
    }
    await illustrationStore.deleteSceneFiles(book, scene.id);
    final manifest = manifestFor(book).copyWith(
      scenes: manifestFor(book).scenes
          .where((item) => item.id != scene.id)
          .toList(),
    );
    illustrationManifests[book.hash] = manifest;
    await illustrationStore.saveManifest(book, manifest);
    notifyListeners();
  }

  Future<void>? _narrationShutdown;

  /// Forces reading and audio resume state to disk; awaits shutdown before cleanup.
  Future<void> flush() async {
    if (_pendingPreferences > 0) await _preferenceTail;
    await _narrationShutdown;
    await narration?.flush();
    _positionSave?.cancel();
    await catalogStore.save(books);
  }

  /// Removes the catalog row, source directory, and generated cloud data.
  Future<void> delete(CatalogBook book) async {
    final audio = narration;
    if (audio != null) {
      await audio.detach(book);
      final profile = await audio.store.load(book);
      if (profile.cloudBookId != null) {
        await narrationDeletionOutbox.enqueue(profile.cloudBookId!);
        unawaited(drainNarrationDeletions());
      }
    }
    final cloudBookId = illustrationManifests[book.hash]?.profile?.cloudBookId;
    if (cloudBookId != null && cloudBookId.isNotEmpty) {
      try {
        await illustrationApi.deleteBook(cloudBookId);
      } on Object {
        // The local delete must remain usable while offline, while the cloud
        // privacy request remains durable outside the soon-to-be-deleted book.
        await illustrationDeletionOutbox.enqueue(cloudBookId);
      }
    }
    books = books.where((item) => item.hash != book.hash).toList();
    illustrationManifests.remove(book.hash);
    _textIndexes.remove(book.hash);
    await catalogStore.save(books);
    await catalogStore.deleteFiles(book);
    notifyListeners();
  }

  Future<void>? _deletionDrain;
  Future<void> _drainDeletionOutbox() => _deletionDrain ??=
      _performDeletionDrain().whenComplete(() => _deletionDrain = null);

  Future<void> _performDeletionDrain() async {
    try {
      final pendingDeletions = await illustrationDeletionOutbox.load();
      if (pendingDeletions.isEmpty ||
          !illustrationApi.configured ||
          !await illustrationApi.hasSession()) {
        return;
      }
      for (final pending in pendingDeletions) {
        try {
          await illustrationApi.deleteBook(
            pending.cloudBookId,
            interactive: false,
          );
          await illustrationDeletionOutbox.remove(pending.cloudBookId);
        } on Object {
          // Leave requests durable while connectivity or identity is unavailable.
        }
      }
    } on Object {
      // Startup privacy retries are auxiliary and must never block offline reading.
    }
  }

  /// External narration chapter changes request a viewport restore without writes.
  int narrationNavigationRevision = 0;

  /// Signals a committed narration chapter selection or allowance refresh.
  void notifyNarrationNavigation() {
    narrationNavigationRevision++;
    notifyListeners();
  }

  /// Retries durable narration privacy requests using only an existing session.
  Future<void> drainNarrationDeletions() async {
    final api = narration?.api;
    try {
      if (api == null || !api.configured || !await api.hasSession()) return;
      for (final item in await narrationDeletionOutbox.load()) {
        try {
          await api.deleteBook(item.cloudBookId);
          await narrationDeletionOutbox.remove(item.cloudBookId);
        } on Object {
          /* Keep failed requests durable. */
        }
      }
    } on Object {
      /* Startup retries must never prevent offline reading. */
    }
  }

  /// Consent and cleanup complete before creating a new cloud registration.
  Future<void> consentToNarration(CatalogBook book) async {
    await drainNarrationDeletions();
    if ((await narrationDeletionOutbox.load()).isNotEmpty) {
      throw StateError('Cloud cleanup is pending. Retry when connected.');
    }
    await narration?.consent(book);
    await refreshCloudAccount();
  }

  /// Restores account metadata without sign-in, attestation or feature requests.
  Future<void> refreshCloudAccount() async {
    final identity = cloudIdentity;
    if (identity == null || !identity.configured) return;
    try {
      final email = await identity.hasSession() ? identity.email : null;
      if (_disposed) return;
      if (email != cloudEmail) _invalidateUsage();
      cloudEmail = email;
      if (!_disposed) notifyListeners();
    } on Object {
      // Offline startup never blocks local reading or forces authentication.
    }
  }

  /// Explicit library sign-in is independent of per-book generation consent.
  Future<void> signInToCloud() async {
    if (cloudAccountBusy) return;
    final identity = cloudIdentity;
    if (identity == null || !identity.configured) {
      throw const CloudIdentityException(
        'Google sign-in is not configured in this build.',
      );
    }
    cloudAccountBusy = true;
    _invalidateUsage();
    notifyListeners();
    try {
      await identity.signIn();
      await refreshCloudAccount();
      unawaited(_drainDeletionOutbox());
      unawaited(drainNarrationDeletions());
    } finally {
      cloudAccountBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Ends the shared cloud identity session; offline reading is unchanged.
  Future<void> signOutOfCloud() async {
    if (cloudAccountBusy) return;
    cloudAccountBusy = true;
    _invalidateUsage();
    notifyListeners();
    try {
      await narration?.stop();
      if (cloudIdentity != null) {
        await cloudIdentity!.signOut();
      } else if (narration?.api.configured == true) {
        await narration!.api.signOut();
      } else {
        await illustrationApi.signOut();
      }
    } finally {
      // Native selector cleanup can fail after Firebase successfully signs out.
      // Reflect the actual Firebase account rather than a stale UI label.
      cloudEmail = cloudIdentity?.email;
      cloudAccountBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Purges both cloud features before removing the Firebase user. Narration's
  /// shared identity boundary supports macOS without enabling illustrations.
  Future<void> deleteCloudAccount() async {
    if (cloudAccountBusy) return;
    if (narration?.api.configured != true && !illustrationApi.configured) {
      throw const CloudIdentityException(
        'Connect to the cloud service before deleting your account.',
      );
    }
    cloudAccountBusy = true;
    _invalidateUsage();
    notifyListeners();
    try {
      final active = narration?.book;
      if (active != null) await narration!.detach(active);
      if (narration?.api.configured == true) {
        await narration!.api.deleteAccount();
      } else {
        await illustrationApi.deleteAccount();
      }
      if (narration != null) {
        for (final book in books) {
          await narration!.store.clear(book);
          await narration!.store.save(book, const NarrationManifest());
        }
        if (active != null) await narration!.attach(active);
      }
      for (final book in books) {
        for (final scene in manifestFor(book).scenes) {
          await illustrationStore.deleteSceneFiles(book, scene.id);
        }
        final manifest = IllustrationManifest(bookHash: book.hash);
        illustrationManifests[book.hash] = manifest;
        await illustrationStore.saveManifest(book, manifest);
      }
      cloudEmail = null;
    } finally {
      // Local cleanup can fail after Firebase deletion; show the actual identity.
      if (cloudIdentity != null) cloudEmail = cloudIdentity!.email;
      cloudAccountBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _invalidateUsage() {
    _usageEpoch++;
    accountUsage = null;
    usageLoading = false;
    usageError = null;
    usageFailure = null;
  }

  /// Refreshes owned usage without prompting for sign-in or granting consent.
  Future<void> refreshAccountUsage() async {
    if (_disposed || usageLoading || cloudAccountBusy) return;
    _invalidateUsage();
    final api = accountApi;
    if (cloudEmail == null || api?.configured != true) {
      notifyListeners();
      return;
    }
    final epoch = _usageEpoch;
    final email = cloudEmail;
    usageLoading = true;
    notifyListeners();
    try {
      final result = await api!.usage();
      if (_disposed || epoch != _usageEpoch || email != cloudEmail) return;
      accountUsage = result;
    } on AccountUsageException catch (error) {
      if (_disposed || epoch != _usageEpoch || email != cloudEmail) return;
      usageError = error.message;
      usageFailure = error.kind;
    } on Object {
      if (_disposed || epoch != _usageEpoch || email != cloudEmail) return;
      usageError = 'Usage information could not be refreshed. Try again.';
      usageFailure = AccountUsageFailureKind.service;
    } finally {
      if (!_disposed && epoch == _usageEpoch && email == cloudEmail) {
        usageLoading = false;
        notifyListeners();
      }
    }
  }

  /// Counts validated downloaded audio; source books and manifests are excluded.
  Future<int> narrationCacheBytes() async =>
      await narration?.cachedBytes(List.of(books)) ?? 0;

  /// Fences playback/downloads before deleting audio and obsolete resume offsets.
  Future<void> clearNarrationCache() async {
    await narration?.clearAllCache(List.of(books));
    if (!_disposed) notifyListeners();
  }

  /// Applies and persists any supplied reader-wide preference values.
  Future<void> configure({
    ReadingMode? mode,
    ReadingTheme? theme,
    int? fontSize,
    bool? serif,
    String? narrationVoice,
    double? narrationSpeed,
    LibraryFilter? libraryFilter,
    LibrarySort? librarySort,
  }) {
    if (narrationVoice != null &&
        !['marin', 'cedar'].contains(narrationVoice)) {
      return Future.error(
        ArgumentError.value(narrationVoice, 'narrationVoice'),
      );
    }
    if (narrationSpeed != null &&
        (!narrationSpeed.isFinite ||
            narrationSpeed < .75 ||
            narrationSpeed > 2)) {
      return Future.error(
        ArgumentError.value(narrationSpeed, 'narrationSpeed'),
      );
    }
    return _updatePreferences(
      (current) => current.copyWith(
        mode: mode,
        theme: theme,
        fontSize: fontSize,
        serif: serif,
        narrationVoice: narrationVoice,
        narrationSpeed: narrationSpeed,
        libraryFilter: libraryFilter,
        librarySort: librarySort,
      ),
    );
  }

  /// Resets global preferences without removing books, consent, or cached audio.
  Future<void> resetPreferences() =>
      _updatePreferences((_) => const ReaderSettings());

  Future<void> _updatePreferences(
    ReaderSettings Function(ReaderSettings) update,
  ) {
    if (_disposed) return Future.value();
    _pendingPreferences++;
    // Serialize complete preference snapshots and native playback updates so
    // rapid controls cannot persist older values after a later selection.
    final operation = _preferenceTail.then((_) async {
      try {
        final next = update(settings);
        settings = next;
        if (!_disposed) notifyListeners();
        try {
          await narration?.applyPreferences(next);
        } finally {
          await settingsStore.save(next);
        }
      } finally {
        _pendingPreferences--;
      }
    });
    _preferenceTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  void _replace(CatalogBook updated) {
    books = books
        .map((book) => book.hash == updated.hash ? updated : book)
        .toList();
    notifyListeners();
  }

  Future<BookTextIndex> _indexFor(CatalogBook book) async {
    final memory = _textIndexes[book.hash];
    if (memory != null) return memory;
    final stored = await illustrationStore.loadIndex(book);
    if (stored != null) {
      _textIndexes[book.hash] = stored;
      return stored;
    }
    final created = await textIndexer.index(
      sourcePath: book.path,
      bookHash: book.hash,
    );
    _textIndexes[book.hash] = created;
    await illustrationStore.saveIndex(book, created);
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
      final id = await illustrationApi.createChapterJob(
        profile: profile,
        chapter: index.chapters[ordinal],
      );
      jobs[ordinal] = id;
      final updated = manifestFor(book).copyWith(chapterJobs: jobs);
      illustrationManifests[book.hash] = updated;
      await illustrationStore.saveManifest(book, updated);
    }
    notifyListeners();
  }

  Future<void> _advanceIllustrations(
    CatalogBook book,
    TextPosition position,
  ) async {
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
            !illustrationGate.hasPassed(
              anchor: scene.anchor,
              index: index,
              position: position,
            )) {
          continue;
        }
        final released = await illustrationApi.unlockScene(scene.id);
        final imagePath = await illustrationStore.saveImage(
          book,
          scene.id,
          released.image,
        );
        final thumbnailPath = await illustrationStore.saveImage(
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
    } on Object catch (error) {
      // Illustration failures are auxiliary and must never interrupt reading.
      illustrationError = error.toString();
      notifyListeners();
    } finally {
      _advancingIllustrations.remove(book.hash);
    }
  }

  Future<void> _refreshIllustrationJobs(CatalogBook book) async {
    final scenes = List<IllustrationScene>.of(manifestFor(book).scenes);
    for (final jobId in manifestFor(book).chapterJobs.values) {
      final result = await illustrationApi.getJob(jobId);
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
    illustrationManifests[book.hash] = manifest;
    await illustrationStore.saveManifest(book, manifest);
    notifyListeners();
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
    illustrationManifests[book.hash] = manifest;
    await illustrationStore.saveManifest(book, manifest);
    notifyListeners();
  }

  @override
  void dispose() {
    // Start idle shutdown immediately; only unfinished preference work needs a
    // barrier before native disposal. Offline graphs need no shutdown future.
    if (narration != null) {
      _narrationShutdown ??= _pendingPreferences == 0
          ? narration!.dispose()
          : () async {
              await _preferenceTail;
              await narration!.dispose();
            }();
    }
    unawaited(_narrationShutdown);
    _disposed = true;
    _usageEpoch++;
    _positionSave?.cancel();
    super.dispose();
  }
}

/// Minimal nullable-first helper used without a collection dependency.
extension FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
