import 'dart:async';

import 'package:flutter/foundation.dart';

import '../account/account_usage.dart';
import '../account/account_usage_exception.dart';
import '../account/api.dart';
import '../account/http_account_api.dart';
import '../account/usage_coordinator.dart';
import '../catalog/catalog_book.dart';
import '../catalog/catalog_session.dart';
import '../catalog/catalog_store.dart';
import '../catalog/file_catalog_store.dart';
import '../identity/cloud_identity.dart';
import '../identity/cloud_identity_exception.dart';
import '../identity/firebase_cloud_identity.dart';
import '../illustrations/api.dart';
import '../illustrations/document_text_indexer.dart';
import '../illustrations/file_illustration_deletion_outbox.dart';
import '../illustrations/file_illustration_store.dart';
import '../illustrations/gate.dart';
import '../illustrations/http_illustration_api.dart';
import '../illustrations/illustration_coordinator.dart';
import '../illustrations/indexer.dart';
import '../illustrations/memory_illustration_deletion_outbox.dart';
import '../illustrations/outbox.dart';
import '../illustrations/store.dart';
import '../importing/book_importer.dart';
import '../importing/book_picker.dart';
import '../importing/native_book_picker.dart';
import '../narration/api.dart';
import '../narration/file_narration_store.dart';
import '../narration/http_narration_api.dart';
import '../narration/narration_manifest.dart';
import '../narration/native_narration_player.dart';
import '../narration/player.dart';
import '../narration/session.dart';
import '../narration/store.dart';
import '../preferences/preference_settings_store.dart';
import '../preferences/reader_preferences_coordinator.dart';
import '../preferences/settings_store.dart';
import '../text/book_word_counter.dart';
import '../text/document_store.dart';
import '../text/file_book_word_counter.dart';
import '../text/text_position.dart';

/// Owns session state and coordinates UI, persistence, normalized text, and art jobs.
///
/// This remains the app's only shared [ChangeNotifier]. Illustration services
/// are injected boundaries so reading and tests never depend on cloud plugins.
/// Account usage owns its request lifecycle separately; the mutable usage
/// accessors preserve the controller's existing presentation-state contract.
class ReaderController extends ChangeNotifier {
  /// Composes authoritative owners before installing optional narration.
  ReaderController({
    required CatalogStore catalogStore,
    required SettingsStore settingsStore,
    required BookImporter importer,
    required BookPicker picker,
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
    IllustrationGate illustrationGate = const IllustrationGate(),
  }) : narrationDeletionOutbox =
           narrationDeletionOutbox ?? MemoryIllustrationDeletionOutbox() {
    catalog = CatalogSession(
      store: catalogStore,
      importer: importer,
      picker: picker,
      wordCounter: wordCounter ?? FileBookWordCounter(),
      changed: notifyListeners,
    );
    preferences = ReaderPreferencesCoordinator(
      store: settingsStore,
      applyNarrationPreferences: (settings) async {
        await narration?.applyPreferences(settings);
      },
      changed: notifyListeners,
    );
    illustrations = IllustrationCoordinator(
      store: illustrationStore ?? FileIllustrationStore(),
      textIndexer: textIndexer ?? DocumentTextIndexer(),
      api:
          illustrationApi ??
          // Reuse the account/narration session on both native Apple platforms.
          HttpIllustrationApi(
            identity: cloudIdentity ?? FirebaseCloudIdentity(),
          ),
      deletionOutbox:
          illustrationDeletionOutbox ?? MemoryIllustrationDeletionOutbox(),
      gate: illustrationGate,
      currentBook: (book) =>
          catalog.books.where((item) => item.hash == book.hash).firstOrNull,
      narrationOwnsPosition: (book) => narration?.ownsPosition(book) == true,
      refreshCloudAccount: refreshCloudAccount,
      changed: notifyListeners,
    );
    _usage = AccountUsageCoordinator(
      api: accountApi,
      currentEmail: () => cloudEmail,
      accountBusy: () => cloudAccountBusy,
      changed: notifyListeners,
    );
    if (narrationApi != null &&
        narrationPlayer != null &&
        narrationStore != null) {
      narration = NarrationSession(
        api: narrationApi,
        player: narrationPlayer,
        store: narrationStore,
        documents: narrationDocuments,
        preferences: () => preferences.settings,
        isBookAvailable: (candidate) => catalog.books.any(
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
        currentPosition: (book) => catalog.books
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
  AccountUsage? get accountUsage => _usage.usage;
  set accountUsage(AccountUsage? value) => _usage.usage = value;

  /// Prevents duplicate refresh actions without blocking local preferences.
  bool get usageLoading => _usage.loading;
  set usageLoading(bool value) => _usage.loading = value;

  /// Safe display message; failed refreshes never substitute invented balances.
  String? get usageError => _usage.error;
  set usageError(String? value) => _usage.error = value;

  /// Distinguishes offline, attestation, and service failures in Settings.
  AccountUsageFailureKind? get usageFailure => _usage.failure;
  set usageFailure(AccountUsageFailureKind? value) => _usage.failure = value;

  late final AccountUsageCoordinator _usage;

  /// Restored account label; it is not used to authorize requests or gate reading.
  String? cloudEmail;

  /// Disables duplicate account actions while a native sign-in dialog is active.
  bool cloudAccountBusy = false;

  /// Narration deletion retries stay outside book directories and never sign in.
  final IllustrationDeletionOutbox narrationDeletionOutbox;

  /// Authoritative catalog, serial imports, recency, and position persistence.
  late final CatalogSession catalog;

  /// Authoritative reader settings and serialized native/persistence updates.
  late final ReaderPreferencesCoordinator preferences;

  /// Authoritative illustration sidecars, indexing, and gated cloud workflows.
  late final IllustrationCoordinator illustrations;

  bool _disposed = false;

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
    await Future.wait([catalog.load(), preferences.load()]);
    await illustrations.loadManifests(catalog.books);
    unawaited(illustrations.drainDeletions());
    unawaited(drainNarrationDeletions());
    unawaited(catalog.backfillWordCounts());
    unawaited(refreshCloudAccount());
    notifyListeners();
  }

  /// Records recent activity before navigation enters the reader.
  Future<void> markOpened(CatalogBook book) async {
    if (narration != null && narration!.book?.hash != book.hash) {
      await narration!.pause();
    }
    await catalog.markOpened(book);
  }

  /// Updates the leading text position and evaluates spoiler gates asynchronously.
  Future<void> savePosition(
    CatalogBook book,
    TextPosition position,
    double progress, {
    bool fromNarration = false,
  }) async {
    if (!fromNarration && narration?.ownsPosition(book) == true) return;
    if (_disposed || !catalog.books.any((item) => item.hash == book.hash)) {
      return;
    }
    final saved = catalog.recordPosition(
      book,
      position,
      progress,
      immediate: fromNarration,
    );
    if (fromNarration) {
      // Narration commits must survive suspension before the next audio load.
      await saved;
    }
    unawaited(illustrations.advance(book, position));
  }

  Future<void>? _narrationShutdown;

  /// Forces reading and audio resume state to disk; awaits shutdown before cleanup.
  Future<void> flush() async {
    if (preferences.pendingOperations > 0) await preferences.flush();
    await _narrationShutdown;
    await narration?.flush();
    await catalog.flush();
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
    await illustrations.requestBookDeletion(book);
    catalog.removeFromMemory(book);
    illustrations.forget(book);
    await catalog.persist();
    await catalog.store.deleteFiles(book);
    notifyListeners();
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
      if (email != cloudEmail) _usage.invalidate();
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
    _usage.invalidate();
    notifyListeners();
    try {
      await identity.signIn();
      await refreshCloudAccount();
      unawaited(illustrations.drainDeletions());
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
    _usage.invalidate();
    notifyListeners();
    try {
      await narration?.stop();
      if (cloudIdentity != null) {
        await cloudIdentity!.signOut();
      } else if (narration?.api.configured == true) {
        await narration!.api.signOut();
      } else {
        await illustrations.api.signOut();
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
    if (narration?.api.configured != true && !illustrations.api.configured) {
      throw const CloudIdentityException(
        'Connect to the cloud service before deleting your account.',
      );
    }
    cloudAccountBusy = true;
    _usage.invalidate();
    notifyListeners();
    try {
      final active = narration?.book;
      if (active != null) await narration!.detach(active);
      if (narration?.api.configured == true) {
        await narration!.api.deleteAccount();
      } else {
        await illustrations.api.deleteAccount();
      }
      if (narration != null) {
        for (final book in catalog.books) {
          await narration!.store.clear(book);
          await narration!.store.save(book, const NarrationManifest());
        }
        if (active != null) await narration!.attach(active);
      }
      await illustrations.clearLocalAccountData(catalog.books);
      cloudEmail = null;
    } finally {
      // Local cleanup can fail after Firebase deletion; show the actual identity.
      if (cloudIdentity != null) cloudEmail = cloudIdentity!.email;
      cloudAccountBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Refreshes owned usage without prompting for sign-in or granting consent.
  Future<void> refreshAccountUsage() => _usage.refresh();

  /// Counts validated downloaded audio; source books and manifests are excluded.
  Future<int> narrationCacheBytes() async =>
      await narration?.cachedBytes(List.of(catalog.books)) ?? 0;

  /// Fences playback/downloads before deleting audio and obsolete resume offsets.
  Future<void> clearNarrationCache() async {
    await narration?.clearAllCache(List.of(catalog.books));
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    // Start idle shutdown immediately; only unfinished preference work needs a
    // barrier before native disposal. Offline graphs need no shutdown future.
    if (narration != null) {
      _narrationShutdown ??= preferences.pendingOperations == 0
          ? narration!.dispose()
          : () async {
              await preferences.flush();
              await narration!.dispose();
            }();
    }
    unawaited(_narrationShutdown);
    _disposed = true;
    _usage.dispose();
    catalog.dispose();
    preferences.dispose();
    super.dispose();
  }
}
