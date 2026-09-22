import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flureadium/flureadium.dart';
import 'package:reader/controller.dart';
import 'package:reader/epub_service.dart';
import 'package:reader/illustrations/api.dart';
import 'package:reader/illustrations/gate.dart';
import 'package:reader/illustrations/indexer.dart';
import 'package:reader/illustrations/models.dart';
import 'package:reader/illustrations/outbox.dart';
import 'package:reader/illustrations/store.dart';
import 'package:reader/models.dart';

import 'fakes.dart';

void main() {
  test('illustration profiles version temporal continuity jobs', () {
    const current = IllustrationProfile(
      enabled: true,
      style: 'Ink',
      density: 2,
      styleVersion: 1,
      cloudBookId: 'book',
    );
    expect(current.analysisVersion, 2);
    expect(current.toJson()['analysisVersion'], 2);

    final legacy = IllustrationProfile.fromJson({
      'enabled': true,
      'style': 'Ink',
      'density': 2,
      'styleVersion': 1,
      'cloudBookId': 'book',
    });
    expect(legacy.analysisVersion, 2);
  });

  group('EPUB illustration index', () {
    test(
      'indexes only spine XHTML and produces stable sanitized blocks',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'reader-index-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final epub = File('${directory.path}/book.epub');
        final original = _epubBytes();
        await epub.writeAsBytes(original);

        final indexer = ArchiveEpubTextIndexer();
        final first = await indexer.index(
          epubPath: epub.path,
          bookHash: 'book-hash',
        );
        final second = await indexer.index(
          epubPath: epub.path,
          bookHash: 'book-hash',
        );

        expect(first.chapters, hasLength(2));
        expect(first.chapters.first.language, 'en');
        expect(first.chapters.map((chapter) => chapter.href), [
          'text/one.xhtml',
          'text/two.xhtml',
        ]);
        expect(
          first.chapters.first.paragraphs.map((paragraph) => paragraph.text),
          containsAll([
            'Chapter One',
            'Hello “reader”.',
            'A moonlit gate',
            'Mountain crest',
          ]),
        );
        expect(
          first.chapters.first.paragraphs
              .map((paragraph) => paragraph.text)
              .join(' '),
          isNot(contains('spoiler script')),
        );
        expect(
          first.chapters.first.paragraphs.map((paragraph) => paragraph.id),
          second.chapters.first.paragraphs.map((paragraph) => paragraph.id),
        );
        expect(await epub.readAsBytes(), original);
      },
    );

    test('rejects archive path traversal before reading content', () async {
      final directory = await Directory.systemTemp.createTemp('reader-index-');
      addTearDown(() => directory.delete(recursive: true));
      final archive = Archive()
        ..addFile(ArchiveFile.string('../escape', 'nope'));
      final epub = File('${directory.path}/unsafe.epub');
      await epub.writeAsBytes(ZipEncoder().encode(archive));

      expect(
        () => ArchiveEpubTextIndexer().index(
          epubPath: epub.path,
          bookHash: 'book-hash',
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('locator gate never releases at the ending paragraph', () {
    const paragraphs = [
      IndexedParagraph(
        id: 'p1',
        text: 'One',
        cssSelector: 'body > p:nth-of-type(1)',
        ordinal: 0,
        progression: 0,
      ),
      IndexedParagraph(
        id: 'p2',
        text: 'Two',
        cssSelector: 'body > p:nth-of-type(2)',
        ordinal: 1,
        progression: .5,
      ),
      IndexedParagraph(
        id: 'p3',
        text: 'Three',
        cssSelector: 'body > p:nth-of-type(3)',
        ordinal: 2,
        progression: 1,
      ),
    ];
    const index = BookTextIndex(
      bookHash: 'hash',
      chapters: [
        ChapterTextIndex(
          href: 'one.xhtml',
          spineOrdinal: 0,
          title: null,
          paragraphs: paragraphs,
        ),
        ChapterTextIndex(
          href: 'two.xhtml',
          spineOrdinal: 1,
          title: null,
          paragraphs: paragraphs,
        ),
      ],
    );
    const anchor = SceneAnchor(
      href: 'one.xhtml',
      spineOrdinal: 0,
      paragraphId: 'p2',
      cssSelector: 'body > p:nth-of-type(2)',
      fallbackProgression: .5,
    );
    const gate = IllustrationGate();

    expect(
      gate.hasPassed(
        anchor: anchor,
        index: index,
        locator: const Locator(
          href: 'one.xhtml',
          type: 'application/xhtml+xml',
          locations: Locations(cssSelector: 'body > p:nth-of-type(2)'),
        ),
      ),
      isFalse,
    );
    expect(
      gate.hasPassed(
        anchor: anchor,
        index: index,
        locator: const Locator(
          href: 'one.xhtml',
          type: 'application/xhtml+xml',
          locations: Locations(progression: .99),
        ),
      ),
      isFalse,
    );
    expect(
      gate.hasPassed(
        anchor: anchor,
        index: index,
        locator: const Locator(
          href: 'one.xhtml',
          type: 'application/xhtml+xml',
          locations: Locations(cssSelector: 'body > p:nth-of-type(3)'),
        ),
      ),
      isTrue,
    );
    expect(
      gate.hasPassed(
        anchor: anchor,
        index: index,
        locator: const Locator(
          href: 'two.xhtml',
          type: 'application/xhtml+xml',
        ),
      ),
      isTrue,
    );
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
          href: '$chapter.xhtml',
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
        lastLocator: const Locator(
          href: '0.xhtml',
          type: 'application/xhtml+xml',
        ).toJson(),
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
              href: '0.xhtml',
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
        importer: EpubImporter(
          root: Directory.systemTemp,
          engine: FakeEngine(testPublication()),
        ),
        picker: FakePicker(),
        engine: FakeEngine(testPublication()),
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

      await controller.saveLocator(
        book,
        const Locator(
          href: '0.xhtml',
          type: 'application/xhtml+xml',
          locations: Locations(cssSelector: 'body > p:nth-of-type(2)'),
        ),
      );
      await _waitUntil(() => controller.manifestFor(book).scenes.isNotEmpty);
      expect(api.unlockedSceneIds, isEmpty);

      await controller.saveLocator(
        book,
        const Locator(
          href: '0.xhtml',
          type: 'application/xhtml+xml',
          locations: Locations(cssSelector: 'body > p:nth-of-type(3)'),
        ),
      );
      await _waitUntil(() => api.unlockedSceneIds.isNotEmpty);
      expect(controller.pendingRevealFor(book)?.id, 'scene-0');

      await controller.saveLocator(
        book,
        const Locator(href: '1.xhtml', type: 'application/xhtml+xml'),
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

List<int> _epubBytes() {
  const container = '''<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''';
  const opf = '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <manifest>
    <item id="one" href="text/one.xhtml" media-type="application/xhtml+xml"/>
    <item id="two" href="text/two.xhtml" media-type="application/xhtml+xml"/>
    <item id="unused" href="unused.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="one"/><itemref idref="two"/></spine>
</package>''';
  const one = '''<html xmlns="http://www.w3.org/1999/xhtml" lang="en"><head>
<title>One</title><style>.secret { display: none; }</style></head><body>
<h1>Chapter One</h1><p>Hello “reader”.</p>
<p><img src="gate.png" alt="A moonlit gate"/></p>
<img src="mountain.png" alt="Mountain crest"/>
<p hidden="hidden">Hidden future</p><script>spoiler script</script>
</body></html>''';
  const two = '''<html xmlns="http://www.w3.org/1999/xhtml" dir="rtl"><head><title>Two</title></head>
<body><p>مرحبا بالعالم</p></body></html>''';
  final archive = Archive()
    ..addFile(ArchiveFile.string('META-INF/container.xml', container))
    ..addFile(ArchiveFile.string('OEBPS/content.opf', opf))
    ..addFile(ArchiveFile.string('OEBPS/text/one.xhtml', one))
    ..addFile(ArchiveFile.string('OEBPS/text/two.xhtml', two))
    ..addFile(
      ArchiveFile.string(
        'OEBPS/unused.xhtml',
        '<html><body><p>Must not be indexed</p></body></html>',
      ),
    );
  return ZipEncoder().encode(archive);
}
