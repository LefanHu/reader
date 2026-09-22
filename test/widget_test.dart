import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flureadium/flureadium.dart';
import 'package:reader/controller.dart';
import 'package:reader/epub_service.dart';
import 'package:reader/library.dart';
import 'package:reader/illustrations/models.dart';
import 'package:reader/models.dart';
import 'package:reader/reader.dart';
import 'package:reader/theme.dart';

import 'fakes.dart';

void main() {
  // Reader tests inject a Flutter-only view because platform views and method
  // channels are unavailable in the widget-test process.
  testWidgets('empty library presents the EPUB import action', (tester) async {
    final controller = await testController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: readerTheme,
        home: LibraryScreen(controller: controller),
      ),
    );
    expect(find.text('Your shelf is ready'), findsOneWidget);
    expect(find.text('Import EPUBs'), findsWidgets);
  });

  testWidgets('library search, filters, sorting, and deletion work', (
    tester,
  ) async {
    final reading = testBook(
      locator: {
        'href': 'chapter.xhtml',
        'type': 'application/xhtml+xml',
        'locations': {'totalProgression': .4},
      },
    );
    final second = CatalogBook(
      hash: 'def456',
      fileName: 'z.epub',
      path: '/tmp/z.epub',
      title: 'Another Book',
      authors: const ['Zed'],
      progress: 1,
      addedAt: DateTime.utc(2025),
    );
    final controller = await testController(books: [reading, second]);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: readerTheme,
        home: LibraryScreen(controller: controller),
      ),
    );
    await tester.enterText(find.byType(TextField), 'zed');
    await tester.pump();
    expect(find.text('Another Book'), findsWidgets);
    expect(find.text('Test Book'), findsNothing);
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('All books'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finished').last);
    await tester.pumpAndSettle();
    expect(find.text('Another Book'), findsWidgets);
    expect(find.text('Test Book'), findsNothing);
    await tester.ensureVisible(find.byTooltip('Book actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Book actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(controller.books, hasLength(1));
  });

  testWidgets(
    'reader restores and saves locator, changes mode, and navigates nested TOC',
    (tester) async {
      final nested = const Link(
        href: 'part.xhtml',
        type: 'application/xhtml+xml',
        title: 'Part one',
        children: [
          Link(
            href: 'child.xhtml',
            type: 'application/xhtml+xml',
            title: 'Nested chapter',
          ),
        ],
      );
      final publication = testPublication(toc: [nested]);
      final saved = const Locator(
        href: 'chapter.xhtml',
        type: 'application/xhtml+xml',
        locations: Locations(totalProgression: .25),
      );
      final book = testBook(locator: saved.toJson());
      final controller = await testController(
        books: [book],
        publication: publication,
      );
      final engine = controller.engine as FakeEngine;
      addTearDown(controller.dispose);
      Locator? restored;
      ValueChanged<Locator>? reportLocator;
      await tester.pumpWidget(
        MaterialApp(
          theme: readerTheme,
          home: ReaderScreen(
            book: book,
            controller: controller,
            readerBuilder:
                ({
                  required publication,
                  required initialLocator,
                  required onTap,
                  required onExternalLink,
                  required onLocatorChanged,
                  required onReady,
                }) {
                  restored = initialLocator;
                  reportLocator = onLocatorChanged;
                  return const ColoredBox(
                    color: Colors.white,
                    child: Center(child: Text('Native reader')),
                  );
                },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(restored?.href, saved.href);
      expect(restored?.locations?.totalProgression, .25);
      reportLocator!(
        const Locator(
          href: 'child.xhtml',
          type: 'application/xhtml+xml',
          title: 'Nested chapter',
          locations: Locations(totalProgression: .6),
        ),
      );
      await tester.pump();
      expect(controller.books.single.progress, .6);
      await tester.tap(find.byTooltip('Reading settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pages'));
      await tester.pumpAndSettle();
      expect(controller.settings.mode, ReadingMode.pages);
      expect(engine.preferences?.verticalScroll, isFalse);
      await tester.tap(find.byTooltip('Close settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Choose chapter'));
      await tester.pumpAndSettle();
      expect(find.text('Nested chapter'), findsWidgets);
      await tester.tap(find.text('Nested chapter').last);
      await tester.pumpAndSettle();
      expect(engine.visitedLink?.href, 'child.xhtml');
    },
  );

  testWidgets(
    'external links require domain confirmation and controls can hide',
    (tester) async {
      final book = testBook();
      final controller = await testController(books: [book]);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: readerTheme,
          home: ReaderScreen(
            book: book,
            controller: controller,
            readerBuilder:
                ({
                  required publication,
                  required initialLocator,
                  required onTap,
                  required onExternalLink,
                  required onLocatorChanged,
                  required onReady,
                }) => Center(
                  child: TextButton(
                    onPressed: () => onExternalLink('https://example.com/path'),
                    child: const Text('External link'),
                  ),
                ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('External link'));
      await tester.pumpAndSettle();
      expect(find.textContaining('example.com'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Hide reading controls'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Back to library'), findsNothing);
      expect(find.byTooltip('Show reading controls'), findsOneWidget);
    },
  );

  testWidgets('illustration consent precedes chapter scheduling', (
    tester,
  ) async {
    final book = testBook();
    final api = FakeIllustrationApi(configured: true);
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
      textIndexer: FakeTextIndexer(),
      illustrationApi: api,
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: readerTheme,
        home: ReaderScreen(
          book: book,
          controller: controller,
          readerBuilder: ({
            required publication,
            required initialLocator,
            required onTap,
            required onExternalLink,
            required onLocatorChanged,
            required onReady,
          }) => const ColoredBox(color: Colors.white),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('AI illustrations'));
    await tester.pumpAndSettle();

    expect(find.text('Illustrate this book?'), findsOneWidget);
    expect(find.textContaining('EPUB is never uploaded'), findsOneWidget);
    expect(find.textContaining('Estimated maximum: 3 credits'), findsOneWidget);
    expect(api.createdChapterOrdinals, isEmpty);

    await tester.tap(find.text('Enable illustrations'));
    await tester.pumpAndSettle();
    expect(api.createdChapterOrdinals, [0]);
    expect(controller.manifestFor(book).enabled, isTrue);
  });

  testWidgets('gallery exposes only unlocked scenes', (tester) async {
    final book = testBook();
    final store = MemoryIllustrationStore();
    store.manifests[book.hash] = IllustrationManifest(
      bookHash: book.hash,
      profile: const IllustrationProfile(
        enabled: true,
        style: 'Cinematic ink',
        density: 3,
        styleVersion: 1,
        cloudBookId: 'cloud-book',
      ),
      scenes: const [
        IllustrationScene(
          id: 'unlocked',
          state: IllustrationSceneState.unlocked,
          caption: 'The moonlit gate',
          anchor: SceneAnchor(
            href: 'chapter.xhtml',
            spineOrdinal: 0,
            paragraphId: 'p1',
            cssSelector: 'p',
            fallbackProgression: .5,
          ),
        ),
        IllustrationScene(
          id: 'locked',
          state: IllustrationSceneState.readyLocked,
          caption: 'Future spoiler',
          anchor: SceneAnchor(
            href: 'chapter.xhtml',
            spineOrdinal: 0,
            paragraphId: 'p2',
            cssSelector: 'p + p',
            fallbackProgression: 1,
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
      illustrationStore: store,
      textIndexer: FakeTextIndexer(),
      illustrationApi: FakeIllustrationApi(configured: true),
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: readerTheme,
        home: ReaderScreen(
          book: book,
          controller: controller,
          readerBuilder: ({
            required publication,
            required initialLocator,
            required onTap,
            required onExternalLink,
            required onLocatorChanged,
            required onReady,
          }) => const ColoredBox(color: Colors.white),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('AI illustrations'));
    await tester.pumpAndSettle();

    expect(find.text('Illustrated scenes'), findsOneWidget);
    expect(find.text('The moonlit gate'), findsOneWidget);
    expect(find.text('Future spoiler'), findsNothing);
  });
}
