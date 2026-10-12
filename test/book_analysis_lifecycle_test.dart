import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/book_analysis/api.dart';
import 'package:reader/book_analysis/http_book_analysis_api.dart';
import 'package:reader/book_analysis/analysis_coordinator.dart';
import 'package:reader/book_analysis/analysis_entity.dart';
import 'package:reader/book_analysis/book_analysis_state.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/text/text_block.dart';
import 'package:reader/text/text_position.dart';
import 'package:reader/text/text_section.dart';
import 'package:reader/illustrations/http_illustration_api.dart';

import 'support/dev_api_books.dart';
import 'support/dev_api_client.dart';
import 'support/dev_api_environment.dart';
import 'support/dev_api_identity.dart';

import 'support/fake_book_analysis_api.dart';
import 'support/memory_analysis_store.dart';
import 'support/memory_document_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'consent blocks all cloud requests and signed out waits without upload',
    () async {
      final h = _Harness(consent: false);
      addTearDown(h.dispose);
      await h.start();
      await _until(() => h.state.status == BookAnalysisStatus.waitingConsent);
      expect(h.api.configCalls, 0);
      expect(h.api.uploads, isEmpty);
      h.consent = true;
      h.api.signedOut = true;
      h.coordinator.nudge();
      await _until(() => h.state.status == BookAnalysisStatus.waitingAccount);
      final attempts = h.api.configCalls;
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(
        h.api.configCalls,
        attempts,
        reason: 'Missing account is not a login polling loop.',
      );
      expect(h.api.registrations, isEmpty);
      expect(h.api.uploads, isEmpty);
      h.api.signedOut = false;
      h.coordinator.nudge();
      await h.complete();
    },
  );

  test(
    'startup and accepted import process every section without reader opening',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.start();
      await h.complete();
      final imported = _book('b', addedAt: DateTime.utc(2026, 2));
      h.books.add(imported);
      h.coordinator.queue(imported);
      await _until(() => h.coordinator.isComplete(imported));
      expect(h.api.registrations.map((book) => book.hash), [
        h.book.hash,
        imported.hash,
      ]);
      expect(h.api.manifests, hasLength(2));
      for (final manifest in h.api.manifests) {
        expect(manifest.sectionCount, 2);
        expect(
          manifest.chunks
              .expand((chunk) => chunk.primary)
              .map((span) => span.sectionId)
              .toSet(),
          {'s0', 's1'},
        );
      }
      expect(h.books.map((book) => book.lastPosition), everyElement(_anchor));
      expect(h.books.map((book) => book.progress), everyElement(.25));
      expect(
        h.store.pages.values
            .where((page) => page.mentions != null)
            .expand((page) => page.mentions!)
            .map((mention) => mention.surface),
        containsAll(['Mara', 'e\u0301', '👩🏽‍🚀']),
      );
      expect(
        h.store.states[h.book.hash]!.toJson().containsKey('chunks'),
        isFalse,
      );
    },
  );

  test(
    'one active book owns extraction and finalization until publication',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final h = _Harness();
      addTearDown(h.dispose);
      h.books.add(_book('b', addedAt: DateTime.utc(2026, 2)));
      h.api.beforeRequest = (operation) async {
        if (operation == 'chunk' && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      await h.start();
      await entered.future;
      expect(h.api.registrations, hasLength(1));
      release.complete();
      await _until(() => h.books.every(h.coordinator.isComplete));
      final firstGeneration = h.api.uploadGenerations.first;
      final split = h.api.uploadGenerations.indexWhere(
        (id) => id != firstGeneration,
      );
      expect(split, greaterThan(0));
      expect(
        h.api.uploadGenerations.skip(split),
        isNot(contains(firstGeneration)),
      );
    },
  );

  test('lost response and restart adopt durable generation without duplicate extraction', () async {
    final h = _Harness(waiting: const Duration(hours: 1));
    addTearDown(h.dispose);
    h.api.lostChunkResponse = true;
    await h.start();
    await _until(() => h.state.status == BookAnalysisStatus.waitingConnection);
    final admitted = h.state.generationId;
    expect(admitted, isNotNull);
    expect(h.store.states[h.book.hash]!.generationId, admitted);
    expect(h.api.uploads, hasLength(1));
    h.restart();
    await h.start();
    await h.complete();
    expect(h.state.generationId, admitted);
    expect(h.api.manifests, hasLength(1));
    expect(
      h.api.uploads.map((chunk) => chunk.ordinal).toSet().length,
      h.api.uploads.length,
    );
    expect(h.api.finalizations, [admitted]);
  });

  test('admission receipt is durable before manifest and startup reconstructs descriptors', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final h = _Harness();
    addTearDown(h.dispose);
    h.api.beforeRequest = (operation) async {
      if (operation == 'manifest' && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    await h.start();
    await entered.future;
    final admitted = h.store.states[h.book.hash]!.generationId;
    expect(admitted, isNotNull);
    h.coordinator.dispose();
    release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 3));
    h.api.beforeRequest = null;
    h.restart();
    await h.start();
    await h.complete();
    expect(h.state.generationId, admitted);
    expect(h.api.manifests, hasLength(1));
  });

  test('suspension fences an awaited state transaction and resumes exact server intent', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final h = _Harness();
    addTearDown(h.dispose);
    h.store.beforeStateWrite = (state) async {
      if (state.receipt != null && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    await h.start();
    await entered.future;
    final before = h.store.committedStates;
    h.coordinator.setResumed(false);
    release.complete();
    await h.coordinator.flush();
    expect(h.store.committedStates, before);
    expect(h.api.uploads, isEmpty);
    final calls = h.api.configCalls;
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(h.api.configCalls, calls);
    h.coordinator.setResumed(true);
    await h.complete();
    expect(h.api.manifests, hasLength(1));
  });

  test(
    'account action rejects delayed pages and new owner never reuses receipts',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final h = _Harness();
      addTearDown(h.dispose);
      h.store.beforePageWrite = (_) async {
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      await h.start();
      await entered.future;
      final oldGeneration = h.state.generationId;
      h.generation++;
      h.coordinator.invalidateAccount();
      h.api.accountKey = 'b' * 64;
      release.complete();
      await h.coordinator.flush();
      expect(h.store.committedPages, 0);
      h.coordinator.nudge();
      await h.complete();
      expect(h.state.generationId, isNot(oldGeneration));
      expect(h.state.finalized!.accountKey, h.api.accountKey);
      expect(h.api.manifests, hasLength(2));
    },
  );

  test(
    'deleted and reimported exact identity cannot receive delayed local commit',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final h = _Harness();
      addTearDown(h.dispose);
      h.store.beforePageWrite = (_) async {
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      await h.start();
      await entered.future;
      final deleted = h.book;
      h.coordinator.invalidateBook(deleted);
      h.books.clear();
      final reimported = _book('a', addedAt: DateTime.utc(2026, 3));
      h.books.add(reimported);
      release.complete();
      await h.coordinator.flush();
      expect(h.store.committedPages, 0);
      h.coordinator.queue(reimported);
      await _until(() => h.coordinator.isComplete(reimported));
      expect(
        h.coordinator.states[reimported.hash]!.addedAt,
        reimported.addedAt,
      );
    },
  );

  test(
    'late registration is handed to durable deletion owner rather than sidecar',
    () async {
      final identity = await DevApiIdentity.shared();
      final client = DevApiClient.create();
      final baseUri = DevApiEnvironment.instance.baseUri;
      final book = devBook();
      final hold = client.hold(
        (r) => r.method == 'POST' && r.url.path == '/api/book-analysis/books',
      );
      final h = _Harness(
        book: book,
        remoteApi: HttpBookAnalysisApi(
          identity: identity,
          client: client,
          baseUri: baseUri,
        ),
      );
      addTearDown(h.dispose);
      await h.start();
      await hold.started;
      h.coordinator.invalidateBook(h.book);
      h.books.clear();
      hold.release();
      for (var i = 0; i < 1200 && h.abandoned.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final registration = client.exchanges.singleWhere(
        (e) => e.method == 'POST' && e.path == '/api/book-analysis/books',
      );
      expect(registration.status, 200);
      final bookId =
          (jsonDecode(registration.body) as Map<String, dynamic>)['bookId']
              as String;
      deleteDevBookAfterTest(
        HttpIllustrationApi(
          identity: identity,
          client: client,
          baseUri: baseUri,
        ),
        bookId,
      );
      expect(bookId, matches(RegExp(r'^[a-f0-9]{40}$')));
      expect(h.abandoned, [bookId]);
      expect(h.store.states[h.book.hash]?.cloudBookId, isNull);
      expect(
        client.exchanges.where((e) => e.path.contains('/generations')),
        isEmpty,
      );
    },
    timeout: devApiTimeout,
  );

  test(
    'provider failure is terminal and replacement retains old finalized pages',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.start();
      await h.complete();
      final old = h.state.finalized!;
      final oldPageKeys = h.store.pages.keys.toSet();
      h.documents.sections[1] = const TextSection(
        id: 's1',
        blocks: [
          TextBlock(
            id: 'p1',
            text: 'Mara changes her braid beneath the dark sky.',
          ),
        ],
      );
      h.api.failProvider = true;
      h.coordinator.nudge();
      await _until(() => h.state.status == BookAnalysisStatus.failed);
      expect(h.state.failureCategory, 'provider_failed');
      expect(h.state.finalized!.revision, old.revision);
      expect(h.store.pages.keys, containsAll(oldPageKeys));
      final uploads = h.api.uploads.length;
      h.coordinator.nudge();
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(
        h.api.uploads.length,
        uploads,
        reason: 'Terminal failures cannot resubmit paid extraction.',
      );
    },
  );

  test('invalid combining-grapheme evidence is rejected rather than snapped', () async {
    final h = _Harness(
      api: FakeBookAnalysisApi(surfaces: {'e': EntityKind.individual}),
    );
    addTearDown(h.dispose);
    await h.start();
    await _until(() => h.state.status == BookAnalysisStatus.failed);
    expect(h.state.failureCategory, 'invalidResult');
    expect(h.state.finalized, isNull);
    // Earlier valid pages may remain as unreferenced files; no pointer exists.
    expect(h.coordinator.isComplete(h.book), isFalse);
  });

  test(
    'disabled rollout waits and account purge preserves local reading identity',
    () async {
      final h = _Harness(waiting: const Duration(hours: 1));
      addTearDown(h.dispose);
      h.api.enabled = false;
      await h.start();
      await _until(() => h.state.status == BookAnalysisStatus.waitingService);
      expect(h.api.registrations, isEmpty);
      h.api.enabled = true;
      h.coordinator.nudge();
      await h.complete();
      await h.coordinator.clearAccountData(h.books);
      expect(h.store.pages, isEmpty);
      expect(h.state.cloudBookId, isNull);
      expect(h.state.finalized, isNull);
      expect(h.book.lastPosition, _anchor);
      expect(h.book.progress, .25);
    },
  );
}

const _anchor = TextPosition(sectionId: 's0', blockId: 'p0', offset: 5);
CatalogBook _book(String hashCharacter, {DateTime? addedAt}) => CatalogBook(
  wordCount: 0,
  hash: hashCharacter * 64,
  fileName: 'fixture.txt',
  path: '/books/$hashCharacter/fixture.txt',
  title: 'Fixture',
  authors: const [],
  addedAt: addedAt ?? DateTime.utc(2026, 1),
  lastPosition: _anchor,
  progress: .25,
);

class _Harness {
  _Harness({
    this.consent = true,
    FakeBookAnalysisApi? api,
    this.remoteApi,
    CatalogBook? book,
    this.waiting = const Duration(milliseconds: 2),
  }) : api = api ?? FakeBookAnalysisApi(),
       book = book ?? _book('a') {
    books.add(this.book);
    _create();
  }
  final CatalogBook book;
  final books = <CatalogBook>[];
  final FakeBookAnalysisApi api;

  /// Real transport that replaces [api] in the coordinator when provided.
  final BookAnalysisApi? remoteApi;
  final store = MemoryAnalysisStore();
  final documents = MemoryDocumentStore(
    sections: [
      TextSection(
        id: 's0',
        blocks: [
          TextBlock(
            id: 'p0',
            text:
                'Mara arrives with e\u0301 and 👩🏽‍🚀. ${'The patrol walks. ' * 350}',
          ),
        ],
      ),
      const TextSection(
        id: 's1',
        blocks: [
          TextBlock(
            id: 'p1',
            text: 'Mara rests. e\u0301 and 👩🏽‍🚀 watch the valley.',
          ),
        ],
      ),
    ],
  );
  final abandoned = <String>[];
  final Duration waiting;
  late BookAnalysisCoordinator coordinator;
  bool consent;
  int generation = 0;
  BookAnalysisState get state => coordinator.states[book.hash]!;
  void _create() {
    coordinator = BookAnalysisCoordinator(
      api: remoteApi ?? api,
      store: store,
      documents: documents,
      books: () => books,
      isBookLive: (candidate) => books.any(
        (book) =>
            book.hash == candidate.hash &&
            book.path == candidate.path &&
            book.addedAt == candidate.addedAt,
      ),
      uploadEligible: (_) => consent,
      accountGeneration: () => generation,
      changed: () {},
      abandonRegistration: (id) async {
        abandoned.add(id);
      },
      activePollInterval: const Duration(milliseconds: 1),
      waitingPollInterval: waiting,
    );
  }

  Future<void> start() => coordinator.restore(books.toList());
  Future<void> complete() => _until(() => coordinator.isComplete(book));
  void restart() {
    coordinator.dispose();
    _create();
  }

  void dispose() => coordinator.dispose();
}

Future<void> _until(bool Function() condition) async {
  for (var attempt = 0; attempt < 1500; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Analysis lifecycle condition did not complete.');
}
