import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/illustrations/chapter_text_index.dart';
import 'package:reader/file_cloud_deletion_outbox.dart';
import 'package:reader/illustrations/file_illustration_store.dart';
import 'package:reader/illustrations/http_illustration_api.dart';
import 'package:reader/illustrations/illustration_figure.dart';
import 'package:reader/illustrations/illustration_job_result.dart';
import 'package:reader/illustrations/illustration_manifest.dart';
import 'package:reader/illustrations/illustration_profile.dart';
import 'package:reader/illustrations/illustration_scene.dart';
import 'package:reader/illustrations/illustration_selection.dart';
import 'package:reader/illustrations/illustration_setup.dart';
import 'package:reader/illustrations/indexed_paragraph.dart';

import 'support/memory_cloud_deletion_outbox.dart';

import 'package:reader/illustrations/scene_anchor.dart';
import 'package:reader/text/text_position.dart';

import 'support/dev_api_books.dart';
import 'support/dev_api_client.dart';
import 'support/dev_api_environment.dart';
import 'support/dev_api_identity.dart';
import 'support/cloud_identity_fake.dart';
import 'support/fake_illustration_api.dart';
import 'support/fake_text_indexer.dart';
import 'support/test_controller.dart';

void main() {
  test(
    'startup deletion retries never initiate illustration sign-in',
    () async {
      final outbox = MemoryCloudDeletionOutbox();
      await outbox.enqueue('old-book');
      final api = FakeIllustrationApi(configured: true);
      final controller = await testController(
        illustrationApi: api,
        illustrationDeletionOutbox: outbox,
        cloudIdentity: FakeCloudIdentity(),
        initialize: false,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(api.deletedBooks, isEmpty);
      expect(await outbox.load(), hasLength(1));
    },
  );
  test(
    'concurrent privacy requests across outbox instances retain every deletion',
    () async {
      final root = await Directory.systemTemp.createTemp('outbox_concurrent');
      addTearDown(() => root.delete(recursive: true));
      final first = FileCloudDeletionOutbox(
        root,
        fileName: 'illustration-deletions.json',
      );
      final second = FileCloudDeletionOutbox(
        root,
        fileName: 'illustration-deletions.json',
      );
      await Future.wait([
        first.enqueue('a'),
        second.enqueue('b'),
        first.enqueue('c'),
      ]);
      expect((await first.load()).map((item) => item.cloudBookId), [
        'a',
        'b',
        'c',
      ]);
      await Future.wait([first.remove('b'), second.enqueue('d')]);
      expect((await first.load()).map((item) => item.cloudBookId), [
        'a',
        'c',
        'd',
      ]);
    },
  );

  test('deleting a book returns before the server confirms and retries from the outbox', () async {
    final identity = await DevApiIdentity.shared();
    final client = DevApiClient.create();
    final api = HttpIllustrationApi(
      identity: identity,
      client: client,
      baseUri: DevApiEnvironment.instance.baseUri,
    );
    final outbox = MemoryCloudDeletionOutbox();
    final book = devBook();
    final controller = await testController(
      books: [book],
      illustrationApi: api,
      illustrationDeletionOutbox: outbox,
      cloudIdentity: identity,
      analysisReady: (_) => false,
    );
    addTearDown(controller.dispose);
    final setup = await controller.illustrations.beginSetup(book);
    final id = setup.cloudBookId!;
    deleteDevBookAfterTest(api, id);
    await controller.illustrations.confirm(
      book,
      setup: setup,
      selection: IllustrationSelection(
        style: setup.suggestedStyle,
        providerId: 'diagnostic',
      ),
    );
    final hold = client.hold(
      (r) => r.method == 'DELETE' && r.url.path.startsWith('/v1/books/'),
    );

    // The purge is held, so completing proves delete never awaits the server.
    await controller.delete(book);
    expect((await outbox.load()).map((item) => item.cloudBookId), [id]);
    expect(client.exchanges.where((e) => e.method == 'DELETE'), isEmpty);

    hold.release();
    await controller.illustrations.drainDeletions();
    final deletes = client.exchanges.where((e) => e.method == 'DELETE');
    expect(deletes.map((e) => (e.path, e.status)), [('/v1/books/$id', 204)]);
    expect(await outbox.load(), isEmpty);
    final revived = await api.registerBook(book, chapterCount: 1);
    expect(revived.currentProfile, isNull);
  }, timeout: devApiTimeout);
  test('re-enabling a reimported book drains old cloud deletion before registration', () async {
    final identity = await DevApiIdentity.shared();
    final client = DevApiClient.create();
    final api = HttpIllustrationApi(
      identity: identity,
      client: client,
      baseUri: DevApiEnvironment.instance.baseUri,
    );
    final book = devBook();
    final registered = await api.registerBook(book, chapterCount: 1);
    final id = registered.cloudBookId!;
    deleteDevBookAfterTest(api, id);
    await api.confirmProfile(
      IllustrationProfile(
        enabled: true,
        style: 'Ink',
        density: 3,
        providerId: 'diagnostic',
        revision: 0,
        cloudBookId: id,
      ),
    );
    final outbox = MemoryCloudDeletionOutbox();
    await outbox.enqueue(id);
    client.exchanges.clear();
    final controller = await testController(
      books: [book],
      illustrationApi: api,
      illustrationDeletionOutbox: outbox,
      cloudIdentity: identity,
      analysisReady: (_) => false,
    );
    addTearDown(controller.dispose);
    final setup = await controller.illustrations.beginSetup(book);
    expect(await outbox.load(), isEmpty);
    final order = client.exchanges
        .where((e) => e.path == '/v1/books/$id' || e.path == '/v1/books')
        .map((e) => (e.method, e.path, e.status));
    expect(order, [
      ('DELETE', '/v1/books/$id', 204),
      ('POST', '/v1/books', 200),
    ]);
    expect(setup.cloudBookId, id);
    expect(setup.currentProfile, isNull);
  }, timeout: devApiTimeout);

  test('sidecars and cloud deletion outbox recover atomically', () async {
    final directory = await Directory.systemTemp.createTemp('reader-store-');
    addTearDown(() => directory.delete(recursive: true));
    final hash = 'a' * 64;
    final bookDirectory = Directory('${directory.path}/books/$hash')
      ..createSync(recursive: true);
    final epub = File('${bookDirectory.path}/book.epub')
      ..writeAsStringSync('x');
    final book = CatalogBook(
      hash: hash,
      fileName: 'book.epub',
      path: epub.path,
      title: 'Test Book',
      authors: const ['Test Author'],
      addedAt: DateTime.utc(2026),
    );
    final store = FileIllustrationStore(directory);
    final manifest = IllustrationManifest(
      bookHash: hash,
      chapterJobs: {0: 'job-0'},
    );

    await store.saveManifest(book, manifest);
    expect((await store.loadManifest(book)).chapterJobs, {0: 'job-0'});
    final manifestFile = File('${bookDirectory.path}/visuals/manifest.json');
    await manifestFile.rename('${manifestFile.path}.bak');
    await manifestFile.writeAsString('{broken');
    expect((await store.loadManifest(book)).chapterJobs, {0: 'job-0'});
    await File('${manifestFile.path}.bak').delete();
    expect((await store.loadManifest(book)).chapterJobs, isEmpty);

    final outbox = FileCloudDeletionOutbox(
      directory,
      fileName: 'illustration-deletions.json',
    );
    await outbox.enqueue('cloud-book');
    await outbox.enqueue('cloud-book');
    expect(await outbox.load(), hasLength(1));
    await outbox.remove('cloud-book');
    expect(await outbox.load(), isEmpty);
  });

  test('scene identities cannot escape the book image directory', () async {
    final directory = await Directory.systemTemp.createTemp('reader-store-');
    addTearDown(() => directory.delete(recursive: true));
    final hash = 'a' * 64;
    final bookDirectory = Directory('${directory.path}/books/$hash')
      ..createSync(recursive: true);
    final book = CatalogBook(
      hash: hash,
      fileName: 'book.epub',
      path: (File(
        '${bookDirectory.path}/book.epub',
      )..writeAsStringSync('x')).path,
      title: 'Test Book',
      authors: const ['Test Author'],
      addedAt: DateTime.utc(2026),
    );
    final store = FileIllustrationStore(directory);
    final victim = File('${bookDirectory.path}/visuals/escape.webp')
      ..createSync(recursive: true);

    await expectLater(
      store.saveImage(
        book,
        '../escape',
        Uint8List.fromList([1]),
        mimeType: 'image/png',
        generationVersion: 1,
      ),
      throwsFormatException,
    );
    expect(
      Directory('${bookDirectory.path}/visuals')
          .listSync(recursive: true)
          .map((entry) => entry.path),
      [victim.path],
    );
    await store.deleteSceneFiles(book, '../escape');
    expect(victim.existsSync(), isTrue);
  });

  test('controller schedules one chapter ahead and downloads ready art immediately', () async {
    final chapters = List.generate(
      3,
      (chapter) => ChapterTextIndex(
        documentVersion: 1,
        href: 's$chapter',
        spineOrdinal: chapter,
        title: 'Chapter $chapter',
        paragraphs: List.generate(
          3,
          (paragraph) => IndexedParagraph(
            id: 'c$chapter-p$paragraph',
            text: 'Paragraph $paragraph',
            cssSelector: 'body > p:nth-of-type(${paragraph + 1})',
            ordinal: paragraph,
            progression: paragraph / 2,
          ),
        ),
      ),
    );
    final book = CatalogBook(
      hash: 'abc123',
      fileName: 'book.epub',
      path: '/tmp/book.epub',
      title: 'Test Book',
      authors: const ['Test Author'],
      addedAt: DateTime.utc(2026),
      lastPosition: const TextPosition(sectionId: 's0', blockId: 'c0-p0'),
    );
    final api = FakeIllustrationApi(configured: true);
    api.jobResults['job-0'] = IllustrationJobResult(
      id: 'job-0',
      status: 'complete',
      scenes: const [
        IllustrationScene(
          id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          jobId: 'job-0',
          state: IllustrationSceneState.readyLocked,
          anchor: SceneAnchor(
            href: 's0',
            spineOrdinal: 0,
            paragraphId: 'c0-p1',
            cssSelector: 'body > p:nth-of-type(2)',
            fallbackProgression: .5,
          ),
        ),
      ],
    );
    final controller = await testController(
      books: [book],
      textIndexer: FakeTextIndexer(chapters: chapters),
      illustrationApi: api,
      initialize: false,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.illustrations.confirm(
      book,
      setup: const IllustrationSetup(
        cloudBookId: 'cloud-book',
        suggestedStyle: 'Cinematic ink',
        alternativeStyles: [],
        estimatedCredits: 6,
        configuration: FakeIllustrationApi.configuration,
      ),
      selection: const IllustrationSelection(
        style: 'Cinematic ink',
        providerId: 'openai',
      ),
    );
    expect(api.createdChapterOrdinals, [0, 1]);

    await controller.savePosition(
      book,
      const TextPosition(sectionId: 's0', blockId: 'c0-p0'),
      .1,
    );
    // Art downloads immediately; the reader has not reached its anchor yet.
    await _waitUntil(() => api.unlockedSceneIds.isNotEmpty);
    await _waitUntil(
      () =>
          controller.illustrations.figuresFor(book)['s0']?['c0-p1']?.stage ==
          IllustrationFigureStage.ready,
    );
    await controller.savePosition(
      book,
      const TextPosition(sectionId: 's1', blockId: 'c1-p0'),
      .4,
    );
    await _waitUntil(() => api.createdChapterOrdinals.contains(2));
    expect(api.createdChapterOrdinals, [0, 1, 2]);
  });

  test('chapter image jobs wait for finalized preprocessing and resume on completion', () async {
    var ready = false;
    final book = CatalogBook(
      hash: 'abc124',
      fileName: 'book.epub',
      path: '/tmp/book.epub',
      title: 'Test Book',
      authors: const ['Test Author'],
      addedAt: DateTime.utc(2026),
      lastPosition: const TextPosition(sectionId: 's0', blockId: 'p1'),
    );
    final api = FakeIllustrationApi(configured: true);
    final controller = await testController(
      books: [book],
      illustrationApi: api,
      analysisReady: (_) => ready,
    );
    addTearDown(controller.dispose);
    await controller.illustrations.confirm(
      book,
      setup: const IllustrationSetup(
        cloudBookId: 'cloud-book',
        suggestedStyle: 'Cinematic ink',
        alternativeStyles: [],
        estimatedCredits: 6,
        configuration: FakeIllustrationApi.configuration,
      ),
      selection: const IllustrationSelection(
        style: 'Cinematic ink',
        providerId: 'openai',
      ),
    );
    expect(api.createdChapterOrdinals, isEmpty);
    expect(controller.illustrations.figuresFor(book), isEmpty);

    ready = true;
    await controller.illustrations.nudge(book);
    expect(api.createdChapterOrdinals, isNotEmpty);
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}
