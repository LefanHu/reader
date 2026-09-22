// Public state and service members are documented at their owning type and
// behavioral methods; trivial injected-field accessors are intentionally terse.
// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flureadium/flureadium.dart';

import 'epub_service.dart';
import 'illustrations/api.dart';
import 'illustrations/gate.dart';
import 'illustrations/indexer.dart';
import 'illustrations/models.dart';
import 'illustrations/outbox.dart';
import 'illustrations/store.dart';
import 'models.dart';
import 'storage.dart';

/// Owns session state and coordinates UI, persistence, Readium, and art jobs.
///
/// This remains the app's only shared [ChangeNotifier]. Illustration services
/// are injected boundaries so reading and tests never depend on cloud plugins.
class ReaderController extends ChangeNotifier {
  ReaderController({
    required this.catalogStore,
    required this.settingsStore,
    required this.importer,
    required this.picker,
    required this.engine,
    IllustrationStore? illustrationStore,
    EpubTextIndexer? textIndexer,
    IllustrationApi? illustrationApi,
    IllustrationDeletionOutbox? illustrationDeletionOutbox,
    this.illustrationGate = const IllustrationGate(),
  }) : illustrationStore = illustrationStore ?? FileIllustrationStore(),
       textIndexer = textIndexer ?? ArchiveEpubTextIndexer(),
       illustrationApi =
           illustrationApi ??
           HttpIllustrationApi(identity: FirebaseIllustrationIdentity()),
       illustrationDeletionOutbox =
           illustrationDeletionOutbox ?? MemoryIllustrationDeletionOutbox();

  final CatalogStore catalogStore;
  final SettingsStore settingsStore;
  final EpubImporter importer;
  final EpubPicker picker;
  final ReadiumEngine engine;
  final IllustrationStore illustrationStore;
  final EpubTextIndexer textIndexer;
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
  Timer? _locatorSave;
  final Set<String> _advancingIllustrations = {};
  final Map<String, DateTime> _lastIllustrationRefresh = {};

  /// Creates the production dependency graph and restores persisted state.
  static Future<ReaderController> create() async {
    final store = await FileCatalogStore.create();
    final engine = FlureadiumEngine();
    final controller = ReaderController(
      catalogStore: store,
      settingsStore: PreferenceSettingsStore(),
      importer: EpubImporter(root: store.root, engine: engine),
      picker: NativeEpubPicker(),
      engine: engine,
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
    notifyListeners();
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
  /// Flureadium owns one native publication session, so overlapping imports
  /// could close or replace the publication another import is inspecting.
  Future<List<ImportResult>> pickAndImport() async {
    final candidates = await picker.pick();
    if (candidates.isEmpty) return [];
    importing = true;
    importDone = 0;
    importTotal = candidates.length;
    notifyListeners();
    final results = <ImportResult>[];
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
    importing = false;
    notifyListeners();
    return results;
  }

  /// Records recent activity before navigation enters the reader.
  Future<void> markOpened(CatalogBook book) async {
    _replace(book.copyWith(lastOpenedAt: DateTime.now()));
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
      book.lastLocator,
    );
  }

  /// Updates the complete locator and evaluates spoiler gates asynchronously.
  Future<void> saveLocator(CatalogBook book, Locator locator) async {
    final current = books.firstWhere(
      (item) => item.hash == book.hash,
      orElse: () => book,
    );
    final progress = (locator.locations?.totalProgression ?? current.progress)
        .clamp(0.0, 1.0);
    _replace(
      current.copyWith(
        lastLocator: locator.toJson(),
        progress: progress,
        lastOpenedAt: DateTime.now(),
      ),
    );
    _locatorSave?.cancel();
    _locatorSave = Timer(const Duration(milliseconds: 500), () {
      catalogStore.save(books);
    });
    unawaited(_advanceIllustrations(book, locator));
  }

  /// First downloaded scene that has not yet interrupted the reader.
  IllustrationScene? pendingRevealFor(CatalogBook book) {
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

  /// Polls auxiliary work while the reader is idle on a stable locator.
  Future<void> refreshIllustrations(CatalogBook book) async {
    final current = books.where((item) => item.hash == book.hash).firstOrNull;
    final raw = current?.lastLocator ?? book.lastLocator;
    if (raw == null) return;
    final locator = Locator.fromJson(Map<String, dynamic>.of(raw));
    if (locator != null) await _advanceIllustrations(book, locator);
  }

  /// Removes one local and cloud scene without modifying the source EPUB.
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

  /// Forces pending reading state to disk during lifecycle transitions.
  Future<void> flush() async {
    _locatorSave?.cancel();
    await catalogStore.save(books);
  }

  /// Removes the catalog row, source directory, and generated cloud data.
  Future<void> delete(CatalogBook book) async {
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

  Future<void> _drainDeletionOutbox() async {
    if (!illustrationApi.configured) return;
    for (final pending in await illustrationDeletionOutbox.load()) {
      try {
        await illustrationApi.deleteBook(pending.cloudBookId);
        await illustrationDeletionOutbox.remove(pending.cloudBookId);
      } on Object {
        // Leave remaining records durable for the next app launch.
      }
    }
  }

  /// Ends only the illustration identity session; offline reading is unchanged.
  Future<void> signOutOfIllustrations() => illustrationApi.signOut();

  /// Purges server-side illustration data and then removes the Firebase user.
  Future<void> deleteIllustrationAccount() async {
    await illustrationApi.deleteAccount();
    for (final book in books) {
      for (final scene in manifestFor(book).scenes) {
        await illustrationStore.deleteSceneFiles(book, scene.id);
      }
      final manifest = IllustrationManifest(bookHash: book.hash);
      illustrationManifests[book.hash] = manifest;
      await illustrationStore.saveManifest(book, manifest);
    }
    notifyListeners();
  }

  /// Applies and persists any supplied reader-wide preference values.
  Future<void> configure({
    ReadingMode? mode,
    ReadingTheme? theme,
    int? fontSize,
    bool? serif,
  }) async {
    settings = settings.copyWith(
      mode: mode,
      theme: theme,
      fontSize: fontSize,
      serif: serif,
    );
    notifyListeners();
    await settingsStore.save(settings);
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
      epubPath: book.path,
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
    Map<String, dynamic>? rawLocator,
  ) async {
    final profile = manifest.profile;
    if (profile == null || !profile.enabled) return;
    final href = rawLocator?['href'] as String?;
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

  Future<void> _advanceIllustrations(CatalogBook book, Locator locator) async {
    if (_advancingIllustrations.contains(book.hash) ||
        !manifestFor(book).enabled) {
      return;
    }
    _advancingIllustrations.add(book.hash);
    try {
      final index = await _indexFor(book);
      await _scheduleAhead(book, manifestFor(book), index, locator.toJson());
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
              locator: locator,
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
    _locatorSave?.cancel();
    super.dispose();
  }
}

/// Minimal nullable-first helper used without a collection dependency.
extension FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
