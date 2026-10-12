import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/atomic_json_file.dart';
import 'package:reader/book_analysis/analysis_protocol.dart';
import 'package:reader/book_analysis/analysis_result.dart';
import 'package:reader/book_analysis/analysis_limits.dart';
import 'package:reader/book_analysis/book_analysis_state.dart';
import 'package:reader/book_analysis/file_analysis_store.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/text/text_position.dart';

final _generation = 'a' * 64;
final _owner = 'b' * 64;
final _cloudBook = 'c' * 40;
final _digest = 'd' * 64;
final _revision = 'e' * 64;

void main() {
  group('atomic analysis sidecars', () {
    late Directory root;
    late CatalogBook book;
    late FileAnalysisStore store;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('reader-analysis-');
      book = _ownedBook(root, '1' * 64);
      store = FileAnalysisStore(root);
    });
    tearDown(() async {
      await root.delete(recursive: true);
    });
    test('a local-time import round-trips through its UTC sidecar as the same book', () async {
      final local = _book(
        book.path,
        hash: book.hash,
        addedAt: DateTime.fromMicrosecondsSinceEpoch(1700000000123456),
      );
      final page = _page();
      await store.saveState(local, _state(local, page));
      expect((await store.loadState(local))?.matchesBook(local), isTrue);
    });

    test('wire key order and exact Unicode anchors survive immutable pages and pointer restart', () async {
      final page = _page();
      final state = _state(book, page);
      await store.saveState(book, state);
      await store.savePage(book, _generation, page.pageId, page);
      await store.savePage(book, _generation, page.pageId, page);
      await store.saveState(book, _complete(state, page));
      await store.flush();
      final restoredStore = FileAnalysisStore(root);
      final restored = await restoredStore.loadState(book);
      expect(restored!.status, BookAnalysisStatus.complete);
      expect(restored.finalized!.revision, _revision);
      final loaded = await restoredStore.loadPage(
        book,
        _generation,
        page.pageId,
      );
      expect(loaded!.serializedJson, page.serializedJson);
      expect(loaded.mentions!.single.surface, 'e\u0301😀');
      expect(loaded.mentions!.single.span.start.offset, 0);
      expect(loaded.mentions!.single.span.end.offset, 4);
      final original = loaded.serializedJson;
      loaded.toJson()['ordinal'] = 99;
      expect(loaded.serializedJson, original);
      expect(
        book.lastPosition,
        const TextPosition(sectionId: 's0', blockId: 'p0', offset: 2),
      );
      expect(await File(book.path).readAsString(), 'Original local text');
    });

    test('finalized pointer cannot advance until every checksummed page is durable', () async {
      final page = _page();
      final state = _state(book, page);
      await store.saveState(book, state);
      await expectLater(
        store.saveState(book, _complete(state, page)),
        throwsFormatException,
      );
      expect((await store.loadState(book))!.finalized, isNull);
      final wrongPage = AnalysisResultPage.fromJson({
        ...page.toJson(),
        'mentions': [],
      });
      await expectLater(
        store.savePage(book, _generation, page.pageId, wrongPage),
        throwsFormatException,
      );
      expect(await store.loadPage(book, _generation, page.pageId), isNull);
      await store.savePage(book, _generation, page.pageId, page);
      await store.saveState(book, _complete(state, page));
      expect(
        (await store.loadState(book))!.status,
        BookAnalysisStatus.complete,
      );
    });

    test('state and pages recover temporary or backup generations but reject checksum corruption', () async {
      final page = _page();
      await store.saveState(book, _state(book, page));
      await store.savePage(book, _generation, page.pageId, page);
      final stateFile = _stateFile(book);
      await stateFile.rename('${stateFile.path}.tmp');
      await stateFile.writeAsString('{broken');
      expect(
        (await FileAnalysisStore(root).loadState(book))!.receipt!.generationId,
        _generation,
      );
      final pageFile = _pageFile(book, page);
      await pageFile.rename('${pageFile.path}.bak');
      await pageFile.writeAsString('{broken');
      expect(
        (await store.loadPage(book, _generation, page.pageId))!.serializedJson,
        page.serializedJson,
      );
      await File('${pageFile.path}.bak').delete();
      final envelope = _envelope(book, page)
        ..['pageJson'] = page.serializedJson.replaceFirst('e\\u0301', 'X');
      // Change bytes even when the encoder used a literal combining character.
      envelope['pageJson'] = '${envelope['pageJson']} ';
      await pageFile.writeAsString(jsonEncode(envelope));
      expect(await store.loadPage(book, _generation, page.pageId), isNull);
    });

    test('oversized pages reject rather than truncate and immutable content conflicts', () async {
      final page = _page();
      final oversized = {
        ...page.toJson(),
        'padding': 'x' * analysisPageMaxBytes,
      };
      expect(
        () => AnalysisResultPage.fromJson(oversized),
        throwsFormatException,
      );
      await store.saveState(book, _state(book, page));
      await store.savePage(book, _generation, page.pageId, page);
      final alternate = AnalysisResultPage.fromJson({
        ...page.toJson(),
        'mentions': [],
      });
      // A different descriptor cannot repurpose a published immutable page ID.
      await store.saveState(book, _state(book, alternate));
      await expectLater(
        store.savePage(book, _generation, alternate.pageId, alternate),
        throwsFormatException,
      );
      expect(await _pageFile(book, page).readAsString(), contains('é😀'));
    });

    test(
      'exact import and account receipts do not reuse prior owner results',
      () async {
        final page = _page();
        await store.saveState(book, _state(book, page));
        await store.savePage(book, _generation, page.pageId, page);
        final reimport = _book(
          book.path,
          hash: book.hash,
          addedAt: book.addedAt.add(const Duration(seconds: 1)),
        );
        expect(await store.loadState(reimport), isNull);
        expect(
          await store.loadPage(reimport, _generation, page.pageId),
          isNull,
        );
        expect(
          () => store.saveState(reimport, _state(book, page)),
          throwsFormatException,
        );
        await store.clearAccountData([reimport]);
        expect(await _pageFile(book, page).exists(), isTrue);
        await store.saveState(book, _state(book, page, owner: 'f' * 64));
        expect(await store.loadPage(book, _generation, page.pageId), isNull);
        await expectLater(
          store.savePage(book, _generation, page.pageId, page),
          throwsFormatException,
        );
      },
    );

    test(
      'previous finalized pages survive a failed replacement generation',
      () async {
        final page = _page();
        final state = _state(book, page);
        await store.saveState(book, state);
        await store.savePage(book, _generation, page.pageId, page);
        final complete = _complete(state, page);
        await store.saveState(book, complete);
        final replacement = complete.copyWith(
          status: BookAnalysisStatus.failed,
          receipt: AnalysisReceipt(
            generationId: 'f' * 64,
            status: AnalysisGenerationStatus.failed,
          ),
          progress: AnalysisProgress(
            generationId: 'f' * 64,
            bookId: _cloudBook,
            accountKey: _owner,
            documentDigest: _digest,
            status: AnalysisGenerationStatus.failed,
            stage: AnalysisStage.extract,
            processedChunks: 0,
            requiredChunks: 1,
            processedUnits: 0,
            requiredUnits: 4,
            nextCursor: null,
            error: const AnalysisFailure(category: 'provider_failed'),
            finalizedRevision: null,
            resultPages: const [],
          ),
          failureCategory: 'provider_failed',
        );
        await store.saveState(book, replacement);
        expect((await store.loadState(book))!.finalized!.revision, _revision);
        expect(
          (await store.loadPage(
            book,
            _generation,
            page.pageId,
          ))!.mentions!.single.surface,
          'e\u0301😀',
        );
      },
    );

    test('transaction tail fences state and page writes even after temporary flush', () async {
      final page = _page();
      final state = _state(book, page);
      await store.saveState(book, state);
      final stateFile = _stateFile(book);
      store.setWriteEligibility(
        state: (_, _) => !File('${stateFile.path}.tmp').existsSync(),
      );
      await store.saveState(
        book,
        state.copyWith(status: BookAnalysisStatus.waitingConnection),
      );
      expect(
        (await store.loadState(book))!.status,
        BookAnalysisStatus.finalizing,
      );
      expect(await File('${stateFile.path}.tmp').exists(), isFalse);
      final pageFile = _pageFile(book, page);
      store.setWriteEligibility(
        page: (_, _) => !File('${pageFile.path}.tmp').existsSync(),
      );
      await store.savePage(book, _generation, page.pageId, page);
      expect(await store.loadPage(book, _generation, page.pageId), isNull);
      expect(await File('${pageFile.path}.tmp').exists(), isFalse);
      store.setWriteEligibility(state: (_, _) => false, page: (_, _) => false);
      await store.saveState(
        book,
        state.copyWith(status: BookAnalysisStatus.waitingAccount),
      );
      await store.savePage(book, _generation, page.pageId, page);
      expect(
        (await store.loadState(book))!.status,
        BookAnalysisStatus.finalizing,
      );
    });

    test(
      'flush waits for serialized local writes across store instances',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        final blocked = AtomicJsonFile(_stateFile(book)).update(() async {
          entered.complete();
          await release.future;
          return null;
        });
        await entered.future;
        final first = store.saveState(book, BookAnalysisState.forBook(book));
        final otherStore = FileAnalysisStore(root);
        final second = otherStore.saveState(
          book,
          BookAnalysisState.forBook(book)
              .copyWith(status: BookAnalysisStatus.waitingConsent),
        );
        var flushed = false;
        final flush = otherStore.flush().then((_) {
          flushed = true;
        });
        await Future<void>.delayed(Duration.zero);
        expect(flushed, isFalse);
        release.complete();
        await Future.wait([blocked, first, second, flush]);
        expect(
          (await store.loadState(book))!.status,
          BookAnalysisStatus.waitingConsent,
        );
      },
    );

    test('account clear preserves books anchors visuals unrelated files and other books', () async {
      final page = _page();
      final other = _ownedBook(root, '2' * 64);
      await store.saveState(book, _state(book, page));
      await store.savePage(book, _generation, page.pageId, page);
      await store.saveState(other, _state(other, page, owner: 'f' * 64));
      await store.savePage(other, _generation, page.pageId, page);
      final visuals = File(
        '${File(book.path).parent.path}/visuals/manifest.json',
      );
      await visuals.parent.create(recursive: true);
      await visuals.writeAsString('{"consent":"unchanged"}');
      final unrelated = File(
        '${_stateFile(book).parent.path}/private-note.txt',
      );
      await unrelated.writeAsString('not app analysis');
      final malformed = File(
        '${_pageFile(book, page).parent.path}/entities-0.json',
      );
      await malformed.writeAsString('{"not":"an owned page"}');
      await store.clearAccountData([book]);
      expect(await store.loadState(book), isNull);
      expect(await _pageFile(book, page).exists(), isFalse);
      expect((await store.loadState(other))!.accountKey, 'f' * 64);
      expect(await store.loadPage(other, _generation, page.pageId), isNotNull);
      expect(await File(book.path).readAsString(), 'Original local text');
      expect(book.lastPosition!.offset, 2);
      expect(await visuals.readAsString(), '{"consent":"unchanged"}');
      expect(await unrelated.readAsString(), 'not app analysis');
      expect(await malformed.exists(), isTrue);
    });

    test(
      'outside roots symlinks and traversal cannot become analysis storage',
      () async {
        final outside = _book('${root.path}/outside.txt');
        await File(outside.path).writeAsString('outside');
        expect(await store.loadState(outside), isNull);
        expect(
          () => store.saveState(outside, BookAnalysisState.forBook(outside)),
          throwsFormatException,
        );
        final external = Directory('${root.path}/external')..createSync();
        await Link('${File(book.path).parent.path}/analysis')
            .create(external.path);
        expect(await store.loadState(book), isNull);
        expect(
          () => store.saveState(book, BookAnalysisState.forBook(book)),
          throwsFormatException,
        );
        await store.clearAccountData([book]);
        expect(await external.exists(), isTrue);
        expect(external.listSync(), isEmpty);
      },
    );
  });
}

CatalogBook _book(String path, {String? hash, DateTime? addedAt}) =>
    CatalogBook(
      wordCount: 0,
      hash: hash ?? '1' * 64,
      fileName: 'book.txt',
      path: path,
      title: 'Analysis fixture',
      authors: const ['Fixture author'],
      language: 'en',
      addedAt: addedAt ?? DateTime.utc(2026),
      lastPosition: const TextPosition(
        sectionId: 's0',
        blockId: 'p0',
        offset: 2,
      ),
    );

CatalogBook _ownedBook(Directory root, String hash) {
  final directory = Directory('${root.path}/books/$hash')
    ..createSync(recursive: true);
  final file = File('${directory.path}/book.txt')
    ..writeAsStringSync('Original local text');
  return _book(file.path, hash: hash);
}

AnalysisResultPage _page() => AnalysisResultPage.fromJson({
  // Deliberately different from DTO reconstruction order at every object level.
  'mentions': [
    {
      'surface': 'e\u0301😀',
      'role': 'name',
      'entityId': 'entity',
      'id': 'mention',
      'span': {
        'end': {'offset': 4, 'blockId': 'p0', 'sectionId': 's0'},
        'start': {'offset': 0, 'blockId': 'p0', 'sectionId': 's0'},
      },
    },
  ],
  'ordinal': 0, 'kind': 'mentions', 'pageId': 'mentions-0',
  'generationId': _generation,
});

AnalysisResultPageDescriptor _descriptor(AnalysisResultPage page) {
  final bytes = utf8.encode(page.serializedJson);
  return AnalysisResultPageDescriptor(
    pageId: page.pageId,
    kind: page.kind,
    ordinal: page.ordinal,
    checksum: sha256.convert(bytes).toString(),
    byteLength: bytes.length,
  );
}

AnalysisReceipt _receipt() => AnalysisReceipt(
  generationId: _generation,
  jobId: 'f' * 64,
  status: AnalysisGenerationStatus.finalizing,
  cursor: const AnalysisOperationCursor(
    stage: AnalysisStage.reconcile,
    ordinal: 0,
  ),
);

AnalysisProgress _progress(AnalysisResultPage page, {String? owner}) =>
    AnalysisProgress(
      generationId: _generation,
      bookId: _cloudBook,
      accountKey: owner ?? _owner,
      documentDigest: _digest,
      status: AnalysisGenerationStatus.complete,
      stage: AnalysisStage.publish,
      processedChunks: 1,
      requiredChunks: 1,
      processedUnits: 4,
      requiredUnits: 4,
      nextCursor: null,
      error: null,
      finalizedRevision: _revision,
      resultPages: [_descriptor(page)],
    );

BookAnalysisState _state(
  CatalogBook book,
  AnalysisResultPage page, {
  String? owner,
}) => BookAnalysisState.forBook(book).copyWith(
  status: BookAnalysisStatus.finalizing,
  documentDigest: _digest,
  accountKey: owner ?? _owner,
  cloudBookId: _cloudBook,
  receipt: _receipt(),
  progress: _progress(page, owner: owner),
);

BookAnalysisState _complete(BookAnalysisState state, AnalysisResultPage page) =>
    state.copyWith(
      status: BookAnalysisStatus.complete,
      finalized: AnalysisFinalizedPointer(
        generationId: _generation,
        revision: _revision,
        accountKey: state.accountKey!,
        documentDigest: _digest,
        pages: [_descriptor(page)],
      ),
    );

File _stateFile(CatalogBook book) =>
    File('${File(book.path).parent.path}/analysis/state.json');
File _pageFile(CatalogBook book, AnalysisResultPage page) => File(
  '${File(book.path).parent.path}/analysis/pages/${page.generationId}/${page.pageId}.json',
);

Map<String, dynamic> _envelope(CatalogBook book, AnalysisResultPage page) => {
  'bookHash': book.hash,
  'bookPath': book.path,
  'addedAt': book.addedAt.toUtc().toIso8601String(),
  'accountKey': _owner,
  'generationId': page.generationId,
  'pageId': page.pageId,
  'checksum': _descriptor(page).checksum,
  'byteLength': _descriptor(page).byteLength,
  'pageJson': page.serializedJson,
};
