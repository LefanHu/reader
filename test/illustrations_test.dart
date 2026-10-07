import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/controller.dart';
import 'package:reader/book_service.dart';
import 'package:reader/illustrations/api.dart';
import 'package:reader/illustrations/gate.dart';
import 'package:reader/illustrations/models.dart';
import 'package:reader/illustrations/outbox.dart';
import 'package:reader/illustrations/store.dart';
import 'package:reader/models.dart';
import 'package:reader/text/document.dart';

import 'fakes.dart';

void main() {
  test(
    'spoiler gate requires valid identities and a passage beyond the anchor',
    () {
      final chapters = List.generate(
        2,
        (c) => ChapterTextIndex(
          href: 's$c',
          spineOrdinal: c,
          title: null,
          paragraphs: List.generate(
            3,
            (p) => IndexedParagraph(
              id: 'c$c-p$p',
              text: 'مرحبا',
              cssSelector: '',
              ordinal: p,
              progression: p / 2,
            ),
          ),
        ),
      );
      final index = BookTextIndex(bookHash: 'book', chapters: chapters);
      const anchor = SceneAnchor(
        href: 's0',
        spineOrdinal: 0,
        paragraphId: 'c0-p1',
        cssSelector: '',
        fallbackProgression: .5,
      );
      const gate = IllustrationGate();
      bool passed(TextPosition p) =>
          gate.hasPassed(anchor: anchor, index: index, position: p);
      expect(
        passed(
          const TextPosition(sectionId: 's0', blockId: 'c0-p1', offset: 4),
        ),
        isFalse,
      );
      expect(
        passed(
          const TextPosition(sectionId: 's0', blockId: 'c0-p1', offset: 5),
        ),
        isTrue,
      );
      expect(
        passed(const TextPosition(sectionId: 's0', blockId: 'c0-p2')),
        isTrue,
      );
      expect(
        passed(const TextPosition(sectionId: 's1', blockId: 'c1-p0')),
        isTrue,
      );
      expect(
        passed(const TextPosition(sectionId: 's1', blockId: 'missing')),
        isFalse,
      );
      expect(
        passed(
          const TextPosition(sectionId: 's0', blockId: 'c0-p2', version: 9),
        ),
        isFalse,
      );
      expect(
        passed(
          const TextPosition(sectionId: 's0', blockId: 'c0-p2', offset: 99),
        ),
        isFalse,
      );
    },
  );

  test(
    'startup deletion retries never initiate illustration sign-in',
    () async {
      final outbox = MemoryIllustrationDeletionOutbox();
      await outbox.enqueue('old-book');
      final api = FakeIllustrationApi(configured: true)..session = false;
      final controller = ReaderController(
        catalogStore: MemoryCatalogStore(),
        settingsStore: MemorySettingsStore(),
        importer: BookImporter(root: Directory.systemTemp),
        picker: FakePicker(),
        illustrationApi: api,
        illustrationDeletionOutbox: outbox,
      );
      await controller.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(api.deletedBooks, isEmpty);
      expect(await outbox.load(), hasLength(1));
      controller.dispose();
    },
  );
  test(
    'concurrent privacy requests across outbox instances retain every deletion',
    () async {
      final root = await Directory.systemTemp.createTemp('outbox_concurrent');
      addTearDown(() => root.delete(recursive: true));
      final first = FileIllustrationDeletionOutbox(root);
      final second = FileIllustrationDeletionOutbox(root);
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

  test('re-enabling a reimported book drains old cloud deletion before registration', () async {
    final outbox = MemoryIllustrationDeletionOutbox();
    await outbox.enqueue('old-book');
    final api = FakeIllustrationApi(configured: true)..session = false;
    final book = testBook();
    final controller = ReaderController(
      catalogStore: MemoryCatalogStore([book]),
      settingsStore: MemorySettingsStore(),
      importer: BookImporter(root: Directory.systemTemp),
      picker: FakePicker(),
      illustrationApi: api,
      illustrationDeletionOutbox: outbox,
      illustrationStore: MemoryIllustrationStore(),
      textIndexer: FakeTextIndexer(),
    );
    await controller.initialize();
    final setup = await controller.beginIllustrationSetup(book);
    expect(setup.cloudBookId, 'cloud-book');
    expect(api.deletedBooks, ['old-book']);
    expect(await outbox.load(), isEmpty);
    controller.dispose();
  });

  test('sidecars and cloud deletion outbox recover atomically', () async {
    final directory = await Directory.systemTemp.createTemp('reader-store-');
    addTearDown(() => directory.delete(recursive: true));
    final bookDirectory = Directory('${directory.path}/hash')..createSync();
    final epub = File('${bookDirectory.path}/book.epub')
      ..writeAsStringSync('x');
    final book = CatalogBook(
      hash: 'abc123',
      fileName: 'book.epub',
      path: epub.path,
      title: 'Test Book',
      authors: const ['Test Author'],
      addedAt: DateTime.utc(2026),
    );
    final store = FileIllustrationStore();
    const manifest = IllustrationManifest(
      bookHash: 'abc123',
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

    final outbox = FileIllustrationDeletionOutbox(directory);
    await outbox.enqueue('cloud-book');
    await outbox.enqueue('cloud-book');
    expect(await outbox.load(), hasLength(1));
    await outbox.remove('cloud-book');
    expect(await outbox.load(), isEmpty);
  });

  test(
    'controller schedules one chapter ahead and unlocks only past anchor',
    () async {
      final chapters = List.generate(
        3,
        (chapter) => ChapterTextIndex(
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
            id: 'scene-0',
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
      final controller = ReaderController(
        catalogStore: MemoryCatalogStore([book]),
        settingsStore: MemorySettingsStore(),
        importer: BookImporter(root: Directory.systemTemp),
        picker: FakePicker(),
        illustrationStore: MemoryIllustrationStore(),
        textIndexer: FakeTextIndexer(chapters: chapters),
        illustrationApi: api,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.confirmIllustrations(
        book,
        setup: const IllustrationSetup(
          cloudBookId: 'cloud-book',
          suggestedStyle: 'Cinematic ink',
          alternativeStyles: [],
          estimatedCredits: 6,
        ),
        style: 'Cinematic ink',
      );
      expect(api.createdChapterOrdinals, [0, 1]);

      await controller.savePosition(
        book,
        const TextPosition(sectionId: 's0', blockId: 'c0-p1'),
        .1,
      );
      await _waitUntil(() => controller.manifestFor(book).scenes.isNotEmpty);
      expect(api.unlockedSceneIds, isEmpty);
      await controller.savePosition(
        book,
        const TextPosition(sectionId: 's0', blockId: 'c0-p2'),
        .2,
      );
      await _waitUntil(() => api.unlockedSceneIds.isNotEmpty);
      expect(controller.pendingRevealFor(book)?.id, 'scene-0');
      await controller.savePosition(
        book,
        const TextPosition(sectionId: 's1', blockId: 'c1-p0'),
        .4,
      );
      await _waitUntil(() => api.createdChapterOrdinals.contains(2));
      expect(api.createdChapterOrdinals, [0, 1, 2]);
    },
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}
