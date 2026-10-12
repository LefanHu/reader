import 'dart:async';
import 'dart:collection';
import 'dart:io';

import '../catalog/catalog_book.dart';
import '../identity/cloud_failure_kind.dart';
import '../identity/cloud_identity_exception.dart';
import '../identity/cloud_service_exception.dart';
import '../text/document_store.dart';
import 'analysis_protocol.dart';
import 'analysis_source.dart';
import 'analysis_source_models.dart';
import 'analysis_validator.dart';
import 'analysis_versions.dart';
import 'api.dart';
import 'book_analysis_state.dart';
import 'store.dart';

/// Single-flight noninteractive preprocessing, independent of reader opening.
class BookAnalysisCoordinator {
  BookAnalysisCoordinator({
    required this.api,
    required this.store,
    TextDocumentStore? documents,
    required this.books,
    required this.isBookLive,
    required this.uploadEligible,
    required this.accountGeneration,
    required this.changed,
    this.abandonRegistration,
    this.activePollInterval = const Duration(seconds: 4),
    this.waitingPollInterval = const Duration(seconds: 30),
  }) : _source = AnalysisSource(documents: documents) {
    if (store is AnalysisWriteFence) {
      (store as AnalysisWriteFence).setWriteEligibility(
        state: (book, state) =>
            identical(_states[book.hash], state) &&
            (_writeOwners[book.hash]?.current(this) ?? false),
        page: (book, generation) =>
            _states[book.hash]?.generationId == generation &&
            (_writeOwners[book.hash]?.current(this) ?? false),
      );
    }
  }

  final BookAnalysisApi api;
  final AnalysisStore store;
  final List<CatalogBook> Function() books;
  final bool Function(CatalogBook) isBookLive;
  final bool Function(CatalogBook) uploadEligible;
  final int Function() accountGeneration;
  final void Function() changed;
  final Future<void> Function(String cloudBookId)? abandonRegistration;
  final Duration activePollInterval;
  final Duration waitingPollInterval;
  final AnalysisSource _source;
  final Map<String, BookAnalysisState> _states = {};
  final Map<String, AnalysisSourceManifest> _manifests = {};
  final Map<String, (int, String)> _verifiedOwners = {};
  final Map<String, _Owner> _writeOwners = {};
  final Map<String, int> _bookEpochs = {};
  final Set<String> _queued = LinkedHashSet<String>();
  final Map<String, DateTime> _retryAt = {};
  final Set<Future<void>> _writes = {};
  Timer? _timer;
  String? _activeBook;
  Future<void>? _running;
  int _epoch = 0;
  bool _resumed = true;
  bool _disposed = false;
  bool _restoring = false;

  Map<String, BookAnalysisState> get states => UnmodifiableMapView(_states);

  Future<void> restore(List<CatalogBook> restored) async {
    _restoring = true;
    try {
      for (final book in restored) {
        final owner = _capture(book);
        BookAnalysisState? state;
        try {
          state = await store.loadState(book);
        } on FormatException {
          state = BookAnalysisState(
            bookHash: book.hash,
            bookPath: book.path,
            addedAt: book.addedAt,
            status: BookAnalysisStatus.waitingService,
            unavailable: true,
            failureCategory: 'unsupportedSchema',
          );
        }
        if (!_localCurrent(owner)) continue;
        if (state == null || !state.matchesBook(book))
          state = BookAnalysisState.forBook(book);
        _states[book.hash] = state;
        if (!state.unavailable) _queued.add(book.hash);
      }
      if (!_disposed) changed();
    } finally {
      _restoring = false;
      _start();
    }
  }

  void queue(CatalogBook book) {
    if (_disposed || !isBookLive(book)) return;
    final existing = _states[book.hash];
    if (existing == null || !existing.matchesBook(book)) {
      _states[book.hash] = BookAnalysisState.forBook(book);
    }
    if (_states[book.hash]!.unavailable) return;
    _manifests.remove(book.hash);
    _retryAt.remove(book.hash);
    _queued.add(book.hash);
    _start();
  }

  void nudge() {
    if (_disposed) return;
    for (final book in books()) {
      queue(book);
    }
  }

  void setResumed(bool resumed) {
    if (_disposed || _resumed == resumed) return;
    _resumed = resumed;
    if (!resumed) {
      _epoch++;
      _writeOwners.clear();
      _timer?.cancel();
      _timer = null;
    } else {
      nudge();
    }
  }

  /// Called synchronously before any explicit account action starts awaiting.
  void invalidateAccount() {
    _epoch++;
    _writeOwners.clear();
    _verifiedOwners.clear();
    _activeBook = null;
    _timer?.cancel();
    _timer = null;
    _retryAt.clear();
    _queued.clear();
    // Retain old data until the server confirms the same/new owner or deletion.
    // It cannot be consumed while the account action fence is invalidated.
    for (final entry in _states.entries.toList()) {
      if (!entry.value.unavailable) {
        _states[entry.key] = entry.value.copyWith(
          status: BookAnalysisStatus.waitingAccount,
        );
      }
    }
    if (!_disposed) changed();
  }

  void invalidateBook(CatalogBook book) {
    final state = _states[book.hash];
    if (state != null && !state.matchesBook(book)) return;
    _verifiedOwners.remove(book.hash);
    _bookEpochs[book.hash] = (_bookEpochs[book.hash] ?? 0) + 1;
    _writeOwners.remove(book.hash);
    _queued.remove(book.hash);
    _retryAt.remove(book.hash);
    _states.remove(book.hash);
    _manifests.remove(book.hash);
    if (_activeBook == book.hash) _activeBook = null;
    _armTimer();
  }

  Future<void> clearAccountData(List<CatalogBook> retainedBooks) async {
    invalidateAccount();
    await flush();
    await store.clearAccountData(retainedBooks);
    if (_disposed) return;
    for (final book in retainedBooks) {
      if (isBookLive(book))
        _states[book.hash] = BookAnalysisState.forBook(book);
    }
    changed();
  }

  Future<void> flush() async {
    while (_writes.isNotEmpty) {
      await Future.wait(_writes.toList());
    }
    await store.flush();
  }

  bool isComplete(CatalogBook book) {
    final state = _states[book.hash];
    final pointer = state?.finalized;
    return state != null &&
        state.matchesBook(book) &&
        !state.unavailable &&
        state.status == BookAnalysisStatus.complete &&
        pointer != null &&
        _verifiedOwners[book.hash] ==
            (accountGeneration(), pointer.accountKey) &&
        state.accountKey == pointer.accountKey &&
        state.documentVersion == pointer.documentVersion &&
        state.documentDigest == pointer.documentDigest;
  }

  String? cloudBookIdFor(CatalogBook book) {
    final state = _states[book.hash];
    return state != null && state.matchesBook(book) ? state.cloudBookId : null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    _writeOwners.clear();
    _timer?.cancel();
    _timer = null;
    _queued.clear();
    _retryAt.clear();
  }

  _Owner _capture(CatalogBook book) =>
      _Owner(book, _epoch, accountGeneration(), _bookEpochs[book.hash] ?? 0);

  bool _localCurrent(_Owner owner) =>
      !_disposed &&
      owner.epoch == _epoch &&
      owner.account == accountGeneration() &&
      owner.bookEpoch == (_bookEpochs[owner.book.hash] ?? 0) &&
      isBookLive(owner.book);

  void _start() {
    if (_disposed || !_resumed || _restoring || _running != null) return;
    _running = _drain().whenComplete(() {
      _running = null;
      if (_queued.isNotEmpty &&
          !_disposed &&
          _resumed &&
          (_activeBook == null || _queued.contains(_activeBook))) {
        _start();
      } else {
        _armTimer();
      }
    });
    unawaited(_running);
  }

  Future<void> _drain() async {
    while (!_disposed && _resumed && _queued.isNotEmpty) {
      final hash = _activeBook ?? _queued.first;
      if (!_queued.remove(hash)) break;
      CatalogBook? book;
      for (final candidate in books()) {
        if (candidate.hash == hash && isBookLive(candidate)) {
          book = candidate;
          break;
        }
      }
      if (book == null) {
        _activeBook = null;
        continue;
      }
      final owner = _capture(book);
      _writeOwners[hash] = owner;
      try {
        await _process(owner);
      } on Object catch (error) {
        if (owner.current(this)) await _failure(owner, error);
      }
      if (_activeBook != null && _retryAt.containsKey(hash)) break;
    }
  }

  Future<void> _save(_Owner owner, BookAnalysisState state) async {
    if (!owner.current(this) || state.unavailable) return;
    _states[owner.book.hash] = state;
    final write = store.saveState(owner.book, state);
    _writes.add(write);
    try {
      await write;
    } finally {
      _writes.remove(write);
    }
    if (owner.current(this)) changed();
  }

  BookAnalysisState _state(_Owner owner) => _states[owner.book.hash]!;

  Future<void> _process(_Owner owner) async {
    final book = owner.book;
    var state = _state(owner);
    if (!uploadEligible(book)) {
      _activeBook = null;
      await _save(
        owner,
        state.copyWith(status: BookAnalysisStatus.waitingConsent),
      );
      return;
    }
    if (!api.configured) {
      _activeBook = null;
      await _save(
        owner,
        state.copyWith(status: BookAnalysisStatus.waitingService),
      );
      _retry(owner, waitingPollInterval);
      return;
    }
    final config = await api.getConfiguration();
    if (!owner.current(this)) return;
    if (config.accountKey.isEmpty) {
      _activeBook = null;
      await _save(
        owner,
        state.copyWith(status: BookAnalysisStatus.waitingAccount),
      );
      return;
    }
    if (state.accountKey != null && state.accountKey != config.accountKey) {
      state = state.copyWith(
        clearOwner: true,
        clearFailure: true,
        status: BookAnalysisStatus.queued,
      );
      await _save(owner, state);
      if (!owner.current(this)) return;
    }
    if (!config.enabled ||
        config.schemaVersion != analysisSchemaVersion ||
        config.analysisVersion != bookAnalysisVersion ||
        config.model != analysisModel) {
      _activeBook = null;
      await _save(
        owner,
        state.copyWith(status: BookAnalysisStatus.waitingService),
      );
      _retry(owner, waitingPollInterval);
      return;
    }
    final manifest =
        _manifests[book.hash] ?? await _source.buildManifest(book.path);
    if (!owner.current(this)) return;
    _manifests[book.hash] = manifest;
    if (state.documentDigest != manifest.documentDigest ||
        state.documentVersion != manifest.documentVersion) {
      state = state.copyWith(
        documentDigest: manifest.documentDigest,
        documentVersion: manifest.documentVersion,
        clearGeneration: true,
        clearFailure: true,
        status: BookAnalysisStatus.queued,
      );
      await _save(owner, state);
      if (!owner.current(this)) return;
    }
    _verifiedOwners[book.hash] = (owner.account, config.accountKey);
    if (state.status == BookAnalysisStatus.failed) {
      _activeBook = null;
      return;
    }
    if (state.finalized?.documentDigest == manifest.documentDigest &&
        state.finalized?.documentVersion == manifest.documentVersion &&
        state.finalized?.accountKey == config.accountKey) {
      await _save(owner, state.copyWith(status: BookAnalysisStatus.complete));
      _activeBook = null;
      return;
    }
    _activeBook = book.hash;
    if (state.cloudBookId == null) {
      final registration = await api.registerBook(
        book,
        sectionCount: manifest.sectionCount,
      );
      if (!owner.current(this)) {
        if (!isBookLive(book) && abandonRegistration != null) {
          final write = abandonRegistration!(registration.bookId);
          _writes.add(write);
          try {
            await write;
          } finally {
            _writes.remove(write);
          }
        }
        return;
      }
      if (registration.accountKey != config.accountKey) {
        throw const FormatException('Analysis registration owner changed.');
      }
      state = state.copyWith(
        accountKey: registration.accountKey,
        cloudBookId: registration.bookId,
        status: BookAnalysisStatus.queued,
      );
      await _save(owner, state);
      if (!owner.current(this)) return;
    }
    if (state.receipt == null) {
      final receipt = await api.admitGeneration(manifest, state.cloudBookId!);
      if (!owner.current(this)) return;
      state = state.copyWith(receipt: receipt);
      await _save(owner, state);
      if (!owner.current(this)) return;
    }
    final generation = state.generationId!;
    final pages = analysisDescriptorPages(manifest.chunks);
    for (
      var ordinal = state.manifestPagesUploaded;
      ordinal < pages.length;
      ordinal++
    ) {
      await api.putManifestPage(generation, ordinal, pages[ordinal]);
      if (!owner.current(this)) return;
      state = state.copyWith(manifestPagesUploaded: ordinal + 1);
      await _save(owner, state);
      if (!owner.current(this)) return;
    }
    final progress = await api.getProgress(generation);
    if (!owner.current(this)) return;
    if (progress.generationId != generation ||
        progress.bookId != state.cloudBookId ||
        progress.accountKey != state.accountKey ||
        progress.documentDigest != manifest.documentDigest ||
        progress.documentVersion != manifest.documentVersion ||
        progress.requiredChunks != manifest.chunkCount ||
        progress.processedChunks < 0 ||
        progress.processedChunks > progress.requiredChunks ||
        progress.processedUnits < 0 ||
        progress.processedUnits > progress.requiredUnits) {
      throw const FormatException(
        'Invalid analysis progress ownership or coverage.',
      );
    }
    final status = switch (progress.status) {
      AnalysisGenerationStatus.manifest => BookAnalysisStatus.queued,
      AnalysisGenerationStatus.extracting => BookAnalysisStatus.extracting,
      AnalysisGenerationStatus.finalizing => BookAnalysisStatus.finalizing,
      AnalysisGenerationStatus.complete => BookAnalysisStatus.finalizing,
      AnalysisGenerationStatus.failed => BookAnalysisStatus.failed,
    };
    state = state.copyWith(
      progress: progress,
      status: status,
      failureCategory: progress.error == null
          ? null
          : _safeCategory(progress.error!.category),
      clearFailure: progress.error == null,
    );
    await _save(owner, state);
    if (!owner.current(this)) return;
    if (progress.status == AnalysisGenerationStatus.failed) {
      _activeBook = null;
      return;
    }
    if (progress.status == AnalysisGenerationStatus.complete) {
      await _publish(owner, manifest, progress);
      if (owner.current(this)) _activeBook = null;
      return;
    }
    final cursor = progress.nextCursor;
    if (cursor != null) {
      AnalysisReceipt receipt;
      if (cursor.stage == AnalysisStage.extract) {
        if (cursor.ordinal != progress.processedChunks ||
            cursor.ordinal >= manifest.chunks.length) {
          throw const FormatException('Invalid analysis extraction cursor.');
        }
        final input = await _source.loadChunk(
          book.path,
          manifest.chunks[cursor.ordinal],
        );
        if (!owner.current(this)) return;
        if (!uploadEligible(book)) {
          await _save(
            owner,
            _state(owner).copyWith(status: BookAnalysisStatus.waitingConsent),
          );
          _activeBook = null;
          return;
        }
        receipt = await api.submitChunk(generation, input);
      } else if (cursor.stage == AnalysisStage.manifest) {
        if (cursor.ordinal < 0 || cursor.ordinal >= pages.length) {
          throw const FormatException('Invalid analysis manifest cursor.');
        }
        await api.putManifestPage(
          generation,
          cursor.ordinal,
          pages[cursor.ordinal],
        );
        if (!owner.current(this)) return;
        _retry(owner, activePollInterval);
        return;
      } else {
        receipt = await api.finalize(generation);
      }
      if (!owner.current(this)) return;
      if (receipt.generationId != generation)
        throw const FormatException('Invalid analysis receipt.');
      await _save(owner, _state(owner).copyWith(receipt: receipt));
      if (!owner.current(this)) return;
    }
    _retry(owner, activePollInterval);
  }

  Future<void> _publish(
    _Owner owner,
    AnalysisSourceManifest manifest,
    AnalysisProgress progress,
  ) async {
    final liveManifest = await _source.buildManifest(owner.book.path);
    if (!owner.current(this)) return;
    if (liveManifest.documentDigest != manifest.documentDigest ||
        liveManifest.documentVersion != manifest.documentVersion) {
      throw const FormatException(
        'Analysis source changed before publication.',
      );
    }
    final requiredUnits = manifest.chunks.fold<int>(
      0,
      (total, chunk) =>
          total +
          chunk.primary.fold<int>(
            0,
            (sum, span) => sum + span.endOffset - span.startOffset,
          ),
    );
    if (progress.processedChunks != manifest.chunkCount ||
        progress.requiredUnits != requiredUnits ||
        progress.processedUnits != requiredUnits ||
        progress.finalizedRevision == null) {
      throw const FormatException('Incomplete analysis cannot be published.');
    }
    final pageIds = <String>{};
    final validator = AnalysisValidator(
      documents: _source.documents,
      sourcePath: owner.book.path,
      manifest: manifest,
      isCurrent: () => owner.current(this),
    );
    for (final descriptor in progress.resultPages) {
      if (!pageIds.add(descriptor.pageId))
        throw const FormatException('Duplicate analysis result page.');
      var page = await store.loadPage(
        owner.book,
        progress.generationId,
        descriptor.pageId,
      );
      if (!owner.current(this)) return;
      page ??= await api.getPage(progress.generationId, descriptor.pageId);
      if (!owner.current(this)) return;
      await validator.validate(page, descriptor, progress.generationId);
      if (!owner.current(this)) return;
      final write = store.savePage(
        owner.book,
        progress.generationId,
        descriptor.pageId,
        page,
      );
      _writes.add(write);
      try {
        await write;
      } finally {
        _writes.remove(write);
      }
      if (!owner.current(this)) return;
    }
    validator.finish();
    await _save(
      owner,
      _state(owner).copyWith(
        status: BookAnalysisStatus.complete,
        clearFailure: true,
        finalized: AnalysisFinalizedPointer(
          generationId: progress.generationId,
          revision: progress.finalizedRevision!,
          accountKey: progress.accountKey,
          documentVersion: progress.documentVersion,
          documentDigest: progress.documentDigest,
          pages: List.unmodifiable(progress.resultPages),
        ),
      ),
    );
  }

  Future<void> _failure(_Owner owner, Object error) async {
    final kind = error is CloudServiceException
        ? error.kind
        : error is CloudIdentityException
        ? error.kind
        : null;
    final code = error is CloudServiceException ? error.statusCode : null;
    final status = switch (kind) {
      CloudFailureKind.signedOut ||
      CloudFailureKind.cancelled => BookAnalysisStatus.waitingAccount,
      CloudFailureKind.offline => BookAnalysisStatus.waitingConnection,
      CloudFailureKind.notConfigured ||
      CloudFailureKind.attestation => BookAnalysisStatus.waitingService,
      CloudFailureKind.service =>
        code == 401
            ? BookAnalysisStatus.waitingAccount
            : code == 410
            ? BookAnalysisStatus.failed
            : BookAnalysisStatus.waitingService,
      null =>
        error is SocketException || error is TimeoutException
            ? BookAnalysisStatus.waitingConnection
            : BookAnalysisStatus.failed,
    };
    _activeBook = null;
    try {
      await _save(
        owner,
        _state(owner).copyWith(
          status: status,
          failureCategory: status == BookAnalysisStatus.failed
              ? (error is FormatException
                    ? 'invalidResult'
                    : code == 410
                    ? 'deleted'
                    : 'localStorage')
              : null,
          clearFailure: status != BookAnalysisStatus.failed,
        ),
      );
    } on Object {
      // A broken local store must not turn a catalog import into a failure.
      // Keep the in-memory sanitized status; the next lifecycle can restore.
    }
    if (status == BookAnalysisStatus.waitingConnection ||
        status == BookAnalysisStatus.waitingService) {
      _retry(owner, waitingPollInterval);
    }
  }

  void _retry(_Owner owner, Duration delay) {
    if (!owner.current(this)) return;
    _retryAt[owner.book.hash] = DateTime.now().add(delay);
    _armTimer();
  }

  void _armTimer() {
    _timer?.cancel();
    _timer = null;
    if (_disposed || !_resumed || _retryAt.isEmpty) return;
    final applicable = _activeBook == null
        ? _retryAt.entries.toList()
        : _retryAt.entries.where((entry) => entry.key == _activeBook).toList();
    if (applicable.isEmpty) return;
    applicable.sort((a, b) => a.value.compareTo(b.value));
    final delay = applicable.first.value.difference(DateTime.now());
    _timer = Timer(delay.isNegative ? Duration.zero : delay, () {
      final now = DateTime.now();
      for (final entry in applicable) {
        if (!entry.value.isAfter(now)) {
          _retryAt.remove(entry.key);
          _queued.add(entry.key);
        }
      }
      _start();
    });
  }
}

String _safeCategory(String category) =>
    RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,63}$').hasMatch(category)
    ? category
    : 'provider';

class _Owner {
  const _Owner(this.book, this.epoch, this.account, this.bookEpoch);
  final CatalogBook book;
  final int epoch;
  final int account;
  final int bookEpoch;
  bool current(BookAnalysisCoordinator coordinator) =>
      coordinator._resumed && coordinator._localCurrent(this);
}
