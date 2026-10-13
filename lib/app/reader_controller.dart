import 'dart:async';

import 'package:flutter/foundation.dart';

import '../account/account_usage.dart';
import '../account/account_usage_exception.dart';
import '../account/api.dart';
import '../account/usage_coordinator.dart';
import '../book_analysis/analysis_coordinator.dart';
import '../book_analysis/services.dart';
import '../catalog/catalog_book.dart';
import '../catalog/catalog_session.dart';
import '../catalog/catalog_store.dart';
import '../cloud_deletion_outbox.dart';
import '../cloud_deletion_queue.dart';
import '../generation_fence.dart';
import '../identity/cloud_failure_kind.dart';
import '../identity/cloud_identity.dart';
import '../identity/cloud_identity_exception.dart';
import '../illustrations/api.dart';
import '../illustrations/illustration_coordinator.dart';
import '../illustrations/store.dart';
import '../importing/book_importer.dart';
import '../importing/book_picker.dart';
import '../narration/api.dart';
import '../narration/source.dart';
import '../narration/player.dart';
import '../narration/session.dart';
import '../narration/store.dart';
import '../preferences/reader_preferences_coordinator.dart';
import '../preferences/settings_store.dart';
import '../text/document_store.dart';
import '../text/text_position.dart';
import 'change_signal.dart';

/// Narration dependencies installed together; absent graphs have no narration.
typedef NarrationServices = ({
  NarrationApi api,
  NarrationPlayer player,
  NarrationStore store,
  TextDocumentStore? documents,
});

/// Owns session state and coordinates UI, persistence, normalized text, and art jobs.
///
/// Its own notification covers general state. High-frequency updates publish
/// only through [highlightChanges] and [positionChanges], so a spoken word or a
/// scrolled line rebuilds the widgets presenting it rather than the whole app.
/// Every service is injected by [create] or tests, so reading never depends on
/// cloud plugins.
/// Account usage owns its request lifecycle separately.
class ReaderController extends ChangeNotifier {
  /// Replaces finalized-preprocessing readiness for service-less tests only;
  /// production never sets it, so image intents always wait for real analysis.
  final bool Function(CatalogBook)? analysisReadyForTesting;

  /// Fires when the narration highlight moves; never on the general channel.
  final highlightChanges = ChangeSignal();

  /// Fires when a book's reading position or progress is recorded; never on
  /// the general channel.
  final positionChanges = ChangeSignal();

  /// Composes authoritative owners before installing optional narration.
  ReaderController({
    required CatalogStore catalogStore,
    required SettingsStore settingsStore,
    required BookImporter importer,
    required BookPicker picker,
    required IllustrationStore illustrationStore,
    TextDocumentStore? illustrationDocuments,
    required IllustrationApi illustrationApi,
    required CloudDeletionOutbox illustrationDeletionOutbox,
    required this.narrationSource,
    required CloudDeletionOutbox narrationDeletionOutbox,
    required this.cloudIdentity,
    NarrationServices? narration,
    BookAnalysisServices? analysis,
    this.accountApi,
    @visibleForTesting this.analysisReadyForTesting,
  }) {
    catalog = CatalogSession(
      store: catalogStore,
      importer: importer,
      picker: picker,
      changed: notifyListeners,
      positionChanged: () {
        if (!_disposed) positionChanges.notify();
      },
      acceptedBook: _acceptedBook,
    );
    preferences = ReaderPreferencesCoordinator(
      store: settingsStore,
      isNarrationVoiceAvailable: (voice) => narrationSource.voices.any(
        (candidate) => candidate.identifier == voice,
      ),
      defaultNarrationVoice: () => narrationSource.defaultVoice,
      applyNarrationPreferences: (settings) async {
        await this.narration?.applyPreferences(settings);
      },
      changed: notifyListeners,
    );
    _bookDeletions = CloudDeletionQueue(
      outbox: illustrationDeletionOutbox,
      ready: () async =>
          illustrationApi.configured && await cloudIdentity.hasSession(),
      delete: (id) => illustrationApi.deleteBook(id, interactive: false),
    );
    illustrations = IllustrationCoordinator(
      store: illustrationStore,
      documents: illustrationDocuments ?? TextDocumentStore(),
      api: illustrationApi,
      identity: cloudIdentity,
      deletions: _bookDeletions,
      currentBook: catalog.find,
      narrationOwnsPosition: (book) =>
          this.narration?.ownsPosition(book) == true,
      refreshCloudAccount: refreshCloudAccount,
      analysisReady: (book) =>
          analysisReadyForTesting?.call(book) ??
          this.analysis?.isComplete(book) == true,
      accountActionStarted: _invalidateAnalysisAccount,
      consentConfirmed: (book) {
        this.analysis?.queue(book);
        this.analysis?.nudge();
      },
      changed: notifyListeners,
    );
    _narrationDeletions = CloudDeletionQueue(
      outbox: narrationDeletionOutbox,
      ready: () async {
        final api = this.narration?.api;
        return api != null &&
            api.configured &&
            await cloudIdentity.hasSession();
      },
      delete: (id) => this.narration!.api.deleteBook(id),
    );
    _usage = AccountUsageCoordinator(
      api: accountApi,
      currentEmail: () => cloudEmail,
      accountBusy: () => cloudAccountBusy,
      changed: notifyListeners,
    );
    if (narration != null) {
      this.narration = NarrationSession(
        api: narration.api,
        source: narrationSource,
        player: narration.player,
        store: narration.store,
        documents: narration.documents,
        preferences: () => preferences.settings,
        isBookAvailable: catalog.isLive,
        abandonRegistration: (id) async {
          await _narrationDeletions.enqueue(id);
          unawaited(_narrationDeletions.drain());
        },
        changed: () {
          if (!_disposed) notifyListeners();
        },
        highlightChanged: () {
          if (!_disposed) highlightChanges.notify();
        },
        commit: (book, position, progress) =>
            savePosition(book, position, progress, fromNarration: true),
        currentPosition: (book) => catalog.find(book)?.lastPosition,
      );
    }
    if (analysis != null) {
      this.analysis = BookAnalysisCoordinator(
        api: analysis.api,
        store: analysis.store,
        documents: analysis.documents,
        books: () => catalog.books,
        isBookLive: catalog.isLive,
        uploadEligible: (book) {
          final profile = illustrations.manifests[book.hash]?.profile;
          // Confirmation is upload consent; disabling paid images does not revoke it.
          return profile != null &&
              profile.revision > 0 &&
              profile.cloudBookId.isNotEmpty;
        },
        accountFence: _accountFence,
        abandonRegistration: _bookDeletions.enqueue,
        changed: _analysisChanged,
      );
    }
  }

  /// App-lifetime narration; absent in offline/test dependency graphs.
  NarrationSession? narration;

  /// Default-enabled preprocessing owner; absent only in offline/test graphs.
  BookAnalysisCoordinator? analysis;

  /// Retired synchronously before any explicit account action awaits, so
  /// background analysis never commits results for the previous account.
  final GenerationFence _accountFence = GenerationFence();

  void _acceptedBook(CatalogBook book) {
    try {
      analysis?.queue(book);
    } on Object {
      // Cloud scheduling cannot roll back a committed import; startup reconciles.
    }
  }

  void _analysisChanged() {
    if (_disposed) return;
    notifyListeners();
    for (final book in catalog.books) {
      if (analysis?.isComplete(book) == true &&
          illustrations.manifests[book.hash]?.enabled == true) {
        unawaited(illustrations.nudge(book));
      }
    }
  }

  void _invalidateAnalysisAccount() {
    _accountFence.invalidate();
    analysis?.invalidateAccount();
  }

  /// Background dispatch runs only while resumed; reading state is unaffected.
  void setAppResumed(bool resumed) => analysis?.setResumed(resumed);

  /// Platform voice catalog and synthesis identity, independent of attachment.
  final NarrationSource narrationSource;

  /// Shared account boundary works with core-only configuration and no API URL.
  final CloudIdentity cloudIdentity;

  /// Read-only usage service; absent in offline or core-only dependency graphs.
  final AccountApi? accountApi;

  /// Latest server snapshot belongs only to the currently displayed account.
  AccountUsage? get accountUsage => _usage.usage;

  /// Prevents duplicate refresh actions without blocking local preferences.
  bool get usageLoading => _usage.loading;

  /// Safe display message; failed refreshes never substitute invented balances.
  String? get usageError => _usage.error;

  /// Distinguishes offline, attestation, and service failures in Settings.
  AccountUsageFailureKind? get usageFailure => _usage.failure;

  late final AccountUsageCoordinator _usage;

  /// Restored account label; it is not used to authorize requests or gate reading.
  String? cloudEmail;

  /// Disables duplicate account actions while a native sign-in dialog is active.
  bool cloudAccountBusy = false;

  /// Narration deletion retries stay outside book directories and never sign in.
  late final CloudDeletionQueue _narrationDeletions;

  /// Shared cloud-book registrations: illustrations and preprocessing use one
  /// server identity and purge endpoint, so both deletions share this queue.
  /// Receipts stay outside book directories and retries never sign in.
  late final CloudDeletionQueue _bookDeletions;

  /// Retries every durable cloud deletion once with an existing session.
  Future<void> drainCloudDeletions() =>
      Future.wait([_bookDeletions.drain(), _narrationDeletions.drain()]);

  /// Authoritative catalog, serial imports, recency, and position persistence.
  late final CatalogSession catalog;

  /// Authoritative reader settings and serialized native/persistence updates.
  late final ReaderPreferencesCoordinator preferences;

  /// Authoritative illustration sidecars, indexing, and cloud workflows.
  late final IllustrationCoordinator illustrations;

  bool _disposed = false;

  /// Loads catalog, preferences, and book sidecars at startup.
  Future<void> initialize() async {
    await Future.wait([catalog.load(), preferences.load()]);
    if (!narrationSource.requiresCloudRegistration) {
      // Switching providers chooses its default; removed Apple voices stay unavailable.
      if (!preferences.settings.narrationVoice.startsWith('apple:') &&
          narrationSource.defaultVoice != null) {
        await preferences.configure(
          narrationVoice: narrationSource.defaultVoice,
        );
      }
    } else if (preferences.settings.narrationVoice.startsWith('apple:') &&
        narrationSource.defaultVoice != null) {
      // Cloud has no Apple voices; only the global preference is rewritten, so
      // sidecars keep their voice identity.
      await preferences.configure(narrationVoice: narrationSource.defaultVoice);
    }
    await illustrations.loadManifests(catalog.books);
    await analysis?.restore(catalog.books);
    unawaited(_bookDeletions.drain());
    unawaited(_narrationDeletions.drain());
    unawaited(refreshCloudAccount());
    notifyListeners();
  }

  /// Records recent activity before navigation enters the reader.
  Future<void> markOpened(CatalogBook book) async {
    if (narration != null && narration!.book?.hash != book.hash) {
      await narration!.pause();
    }
    await catalog.markOpened(book);
    analysis?.queue(book);
    analysis?.nudge();
  }

  /// Updates the leading text position and schedules illustration downloads.
  Future<void> savePosition(
    CatalogBook book,
    TextPosition position,
    double progress, {
    bool fromNarration = false,
  }) async {
    if (!fromNarration && narration?.ownsPosition(book) == true) return;
    if (_disposed || catalog.find(book) == null) {
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

  /// Commits a listening-sheet chapter choice as narration-owned progress and
  /// asks the mounted reader to restore it; interrupted audio is invalidated.
  Future<void> narrateChapter(CatalogBook book, String sectionId) async {
    final session = narration;
    if (session == null || session.book?.hash != book.hash) return;
    await session.navigate(book);
    final section = await session.documents.loadSection(book.path, sectionId);
    final document = session.document;
    // Loading a chapter must not navigate a replaced book.
    if (_disposed || document == null || session.book?.hash != book.hash) {
      return;
    }
    await savePosition(
      book,
      section.start,
      document.progress(section, section.start),
      fromNarration: true,
    );
    narrationNavigationRevision++;
    notifyListeners();
  }

  Future<void>? _narrationShutdown;

  /// Forces reading and audio resume state to disk; awaits shutdown before cleanup.
  Future<void> flush() async {
    if (preferences.pendingOperations > 0) await preferences.flush();
    await _narrationShutdown;
    await narration?.flush();
    await analysis?.flush();
    await catalog.flush();
  }

  /// Removes the catalog row, source directory, and generated cloud data.
  Future<void> delete(CatalogBook book) async {
    final analysisBookId = analysis?.cloudBookIdFor(book);
    analysis?.invalidateBook(book);
    // Drain captured local receipts before the source directory can disappear.
    await analysis?.flush();
    final audio = narration;
    if (audio != null) {
      await audio.detach(book);
      final profile = await audio.store.load(book);
      if (profile.cloudBookId != null) {
        await _narrationDeletions.enqueue(profile.cloudBookId!);
        unawaited(_narrationDeletions.drain());
      }
    }
    // Receipts are durable before local deletion continues; the purge runs in
    // the background, so deletion never waits for the network or prompts for
    // sign-in. A reimport's setup drains this queue before registering, so it
    // cannot overtake the purge.
    final cloudBookIds = <String>{
      ?illustrations.manifests[book.hash]?.profile?.cloudBookId,
      ?analysisBookId,
    }..remove('');
    for (final id in cloudBookIds) {
      await _bookDeletions.enqueue(id);
    }
    // drain() is single-flight and swallows errors; failures stay in the outbox.
    unawaited(_bookDeletions.drain());
    catalog.removeFromMemory(book);
    illustrations.forget(book);
    await catalog.persist();
    await catalog.store.deleteFiles(book);
    notifyListeners();
  }

  /// External narration chapter changes request a viewport restore without writes.
  int narrationNavigationRevision = 0;

  /// Drains durable cleanup before creating an authenticated book registration.
  Future<void> registerNarration(CatalogBook book) async {
    if (!narrationSource.requiresCloudRegistration) {
      await narration?.attach(book);
      return;
    }
    _invalidateAnalysisAccount();
    await _narrationDeletions.drain();
    if (await _narrationDeletions.hasPending) {
      throw StateError('Cloud cleanup is pending. Retry when connected.');
    }
    await narration?.register(book);
    await refreshCloudAccount();
    analysis?.nudge();
  }

  /// Restores account metadata without sign-in, attestation or feature requests.
  Future<void> refreshCloudAccount() async {
    final identity = cloudIdentity;
    if (!identity.configured) return;
    try {
      final email = await identity.hasSession() ? identity.email : null;
      if (_disposed) return;
      if (email != cloudEmail) _usage.invalidate();
      cloudEmail = email;
      analysis?.nudge();
      if (!_disposed) notifyListeners();
    } on Object {
      // Offline startup never blocks local reading or forces authentication.
    }
  }

  /// Runs one exclusive account action; [settle] records the resulting email.
  Future<void> _accountAction(
    Future<void> Function() action, {
    required void Function() settle,
  }) async {
    if (cloudAccountBusy) return;
    cloudAccountBusy = true;
    _usage.invalidate();
    _invalidateAnalysisAccount();
    notifyListeners();
    try {
      await action();
    } finally {
      settle();
      cloudAccountBusy = false;
      analysis?.nudge();
      if (!_disposed) notifyListeners();
    }
  }

  /// Explicit library sign-in is independent of cloud generation registration.
  Future<void> signInToCloud() async {
    if (cloudAccountBusy) return;
    if (!cloudIdentity.configured) {
      throw const CloudIdentityException(
        CloudFailureKind.notConfigured,
        'Google sign-in is not configured in this build.',
      );
    }
    await _accountAction(() async {
      await cloudIdentity.signIn();
      await refreshCloudAccount();
      unawaited(_bookDeletions.drain());
      unawaited(_narrationDeletions.drain());
    }, settle: () {});
  }

  /// Ends the shared cloud identity session; offline reading is unchanged.
  Future<void> signOutOfCloud() => _accountAction(
    () async {
      await narration?.stop();
      await cloudIdentity.signOut();
    },
    // Native selector cleanup can fail after Firebase successfully signs out.
    // Reflect the actual Firebase account rather than a stale UI label.
    settle: () => cloudEmail = cloudIdentity.email,
  );

  /// Purges every cloud feature through the account API before removing the
  /// Firebase user, then clears local cloud-derived data.
  Future<void> deleteCloudAccount() async {
    if (cloudAccountBusy) return;
    final account = accountApi;
    if (account == null || !account.configured) {
      throw const CloudIdentityException(
        CloudFailureKind.notConfigured,
        'Connect to the cloud service before deleting your account.',
      );
    }
    await _accountAction(
      () async {
        final active = narration?.book;
        if (active != null) await narration!.detach(active);
        await account.deleteAccount();
        if (narration != null) {
          await narration!.forgetCloudAccount(List.of(catalog.books));
          if (active != null) await narration!.attach(active);
        }
        await illustrations.clearLocalAccountData(catalog.books);
        await analysis?.clearAccountData(List.of(catalog.books));
        cloudEmail = null;
      },
      // Local cleanup can fail after Firebase deletion; show the actual identity.
      settle: () => cloudEmail = cloudIdentity.email,
    );
  }

  /// Refreshes owned usage without prompting for sign-in or registering books.
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
    analysis?.dispose();
    _usage.dispose();
    catalog.dispose();
    preferences.dispose();
    highlightChanges.dispose();
    positionChanges.dispose();
    super.dispose();
  }
}
