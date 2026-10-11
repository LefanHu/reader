import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/importing/book_importer.dart';
import 'package:reader/app/reader_controller.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/preferences/reading_theme.dart';
import 'package:reader/narration/session.dart';
import 'package:reader/narration/cloud_narration_source.dart';
import 'package:reader/narration/narration_sheet.dart';
import 'package:reader/reader/reader_screen.dart';
import 'package:reader/theme.dart';
import 'package:reader/text/text_block.dart' as text;
import 'package:reader/text/text_position.dart' as text;
import 'package:reader/text/text_section.dart' as text;
import 'package:reader/text/viewport.dart';

import 'fixtures/catalog_book.dart';
import 'support/controller_lifecycle.dart';
import 'support/fake_illustration_api.dart';
import 'support/fake_picker.dart';
import 'support/fake_word_counter.dart';
import 'support/memory_catalog_store.dart';
import 'support/memory_document_store.dart';
import 'support/memory_illustration_store.dart';
import 'support/memory_settings_store.dart';
import 'support/test_controller.dart';
import 'support/fake_narration_api.dart';
import 'support/fake_narration_player.dart';
import 'support/memory_narration_store.dart';
import 'support/fixture_local_narration_source.dart';

void main() {
  setUpAll(() async {
    for (final (family, path) in [
      ('Lora', 'assets/fonts/Lora.ttf'),
      ('DM Sans', 'assets/fonts/DMSans.ttf'),
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(path))).load();
    }
  });
  testWidgets(
    'Listen opens registered controls without a consent dialog; hidden button loses semantics',
    (tester) async {
      final api = FakeNarrationApi(), player = FakeNarrationPlayer();
      final book = testBook();
      final documents = MemoryDocumentStore();
      final controller = ReaderController(
        catalogStore: MemoryCatalogStore([book]),
        settingsStore: MemorySettingsStore(),
        importer: BookImporter(root: Directory.systemTemp),
        picker: FakePicker([]),
        illustrationApi: FakeIllustrationApi(),
        illustrationStore: MemoryIllustrationStore(),
        wordCounter: FakeWordCounter(),
        narrationApi: api,
        narrationSource: CloudNarrationSource(api),
        narrationPlayer: player,
        narrationStore: MemoryNarrationStore(),
        narrationDocuments: documents,
      );
      await controller.initialize();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await disposeControllerWithFrames(tester, controller);
      });
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildReaderTheme(ReadingTheme.paper),
          home: ReaderScreen(
            book: book,
            controller: controller,
            documentStore: documents,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Listen'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(NarrationSheet), findsOneWidget);
      expect(api.registrations, 1);
      expect(api.requests, isEmpty);
      expect(player.playing, isFalse);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      final semantics = tester.ensureSemantics();

      await tester.tap(find.byTooltip('Hide reading controls'));
      await tester.pump();
      expect(find.bySemanticsLabel('Listen'), findsNothing);
      semantics.dispose();
    },
  );

  testWidgets(
    'explicit listening sheet start registers and plays without a dialog or an initial progress commit',
    (tester) async {
      const committed = text.TextPosition(
        sectionId: 's0',
        blockId: 'p0',
        offset: 5,
      );
      const start = text.TextPosition(sectionId: 's0', blockId: 'p1');
      final book = testBook(position: committed, progress: .1);
      final api = FakeNarrationApi(), player = FakeNarrationPlayer();
      final cache = MemoryNarrationStore();
      final controller = ReaderController(
        catalogStore: MemoryCatalogStore([book]),
        settingsStore: MemorySettingsStore(),
        importer: BookImporter(root: Directory.systemTemp),
        picker: FakePicker([]),
        illustrationApi: FakeIllustrationApi(),
        illustrationStore: MemoryIllustrationStore(),
        wordCounter: FakeWordCounter(),
        narrationApi: api,
        narrationSource: CloudNarrationSource(api),
        narrationPlayer: player,
        narrationStore: cache,
        narrationDocuments: MemoryDocumentStore(),
      );
      await controller.initialize();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await disposeControllerWithFrames(tester, controller);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showNarrationSheet(context, controller, book, start: start),
                child: const Text('Read from here'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Read from here'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(NarrationSheet), findsOneWidget);
      expect(api.registrations, 1);
      expect(api.requests.first.start, start);
      expect(player.playing, isTrue);
      expect(player.loadedOffset, Duration.zero);
      expect(controller.catalog.books.single.lastPosition, committed);
      expect(controller.catalog.books.single.progress, .1);
      expect(controller.narration!.manifest.anchor, committed);
      player.finish();
      await tester.pumpAndSettle();
      expect(
        controller.catalog.books.single.lastPosition,
        const text.TextPosition(sectionId: 's0', blockId: 'p1', offset: 19),
      );
      expect(controller.narration!.status, NarrationStatus.complete);
    },
  );

  testWidgets(
    'narration progress survives viewport reflow and pause restores without overwriting it',
    (tester) async {
      final api = FakeNarrationApi(), player = FakeNarrationPlayer();
      final book = testBook();
      final documents = MemoryDocumentStore(
        sections: [
          text.TextSection(
            id: 's0',
            blocks: [
              const text.TextBlock(id: 'p0', text: 'First paragraph.'),
              text.TextBlock(id: 'p1', text: 'Long subsequent prose. ' * 200),
            ],
          ),
        ],
      );
      final controller = ReaderController(
        catalogStore: MemoryCatalogStore([book]),
        settingsStore: MemorySettingsStore(),
        importer: BookImporter(root: Directory.systemTemp),
        picker: FakePicker([]),
        illustrationApi: FakeIllustrationApi(),
        illustrationStore: MemoryIllustrationStore(),
        wordCounter: FakeWordCounter(),
        narrationApi: api,
        narrationSource: CloudNarrationSource(api),
        narrationPlayer: player,
        narrationStore: MemoryNarrationStore(),
        narrationDocuments: documents,
      );
      await controller.initialize();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await disposeControllerWithFrames(tester, controller);
      });
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildReaderTheme(ReadingTheme.paper),
          home: ReaderScreen(
            book: book,
            controller: controller,
            documentStore: documents,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await controller.registerNarration(book);
      await controller.narration!.play();
      await tester.pump();
      player.finish();
      await tester.pumpAndSettle();
      final committed = controller.catalog.books.single.lastPosition!;
      expect(
        committed,
        const text.TextPosition(sectionId: 's0', blockId: 'p0', offset: 16),
      );
      await tester.binding.setSurfaceSize(const Size(390, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await controller.preferences.configure(
        mode: ReadingMode.scroll,
        fontSize: 24,
      );
      await tester.pumpAndSettle();
      expect(controller.catalog.books.single.lastPosition, committed);
      final pause = player.remotePause!();
      await tester.pumpAndSettle();
      await pause;
      final navigation = tester
          .widget<TextViewport>(find.byType(TextViewport))
          .navigation;
      expect(navigation.leadingPosition, committed);
      expect(controller.catalog.books.single.lastPosition, committed);
      expect(controller.narration!.status, NarrationStatus.paused);
      final restored = navigation.restore(
        const text.TextPosition(sectionId: 's0', blockId: 'p1', offset: 5),
      );
      await tester.pumpAndSettle();
      await restored;
      expect(controller.catalog.books.single.lastPosition, committed);
      navigation.next();
      await tester.pumpAndSettle();
      expect(controller.narration!.manifest.chunkId, isNull);
    },
  );

  testWidgets(
    'all toolbar actions stay visible at narrow widths with large RTL text',
    (tester) async {
      final book = testBook();
      final controller = await testController(books: [book]);
      addTearDown(controller.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final width in [320.0, 390.0, 700.0]) {
        await tester.binding.setSurfaceSize(Size(width, 800));
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: Directionality(
                textDirection: TextDirection.rtl,
                child: child!,
              ),
            ),
            home: ReaderScreen(
              book: book,
              controller: controller,
              documentStore: MemoryDocumentStore(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final tooltip in [
          'Back to library',
          'Listen',
          'Choose chapter',
          'AI illustrations',
          'Reading settings',
          'Hide reading controls',
        ]) {
          expect(find.byTooltip(tooltip), findsOneWidget);
          final bounds = tester.getRect(find.byTooltip(tooltip));
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(width));
        }
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('cloud listening retains cache and account privacy controls', (
    tester,
  ) async {
    final book = testBook(), documents = MemoryDocumentStore();
    final api = FakeNarrationApi();
    final controller = ReaderController(
      catalogStore: MemoryCatalogStore([book]),
      settingsStore: MemorySettingsStore(),
      importer: BookImporter(root: Directory.systemTemp),
      picker: FakePicker([]),
      illustrationApi: FakeIllustrationApi(),
      illustrationStore: MemoryIllustrationStore(),
      wordCounter: FakeWordCounter(),
      narrationApi: api,
      narrationSource: CloudNarrationSource(api),
      narrationPlayer: FakeNarrationPlayer(),
      narrationStore: MemoryNarrationStore(),
      narrationDocuments: documents,
    );
    await controller.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await disposeControllerWithFrames(tester, controller);
    });
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildReaderTheme(ReadingTheme.paper),
        home: ReaderScreen(
          book: book,
          controller: controller,
          documentStore: documents,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await controller.registerNarration(book);
    await tester.tap(find.byTooltip('Listen'));
    await tester.pumpAndSettle();
    await controller.narration!.play();
    await tester.pump();
    await tester.ensureVisible(find.text('Clear downloaded audio'));
    await tester.tap(find.text('Clear downloaded audio'));
    await tester.pumpAndSettle();
    expect(controller.narration!.book, book);
    expect(controller.narration!.manifest.cloudBookId, isNotNull);
    expect(
      (controller.narration!.store as MemoryNarrationStore).files,
      isEmpty,
    );
    expect(controller.narration!.manifest.chunkId, isNull);
    expect(tester.takeException(), isNull);
    final cloudApi = controller.narration!.api as FakeNarrationApi;
    final anchor = controller.catalog.books.single.lastPosition;
    await tester.ensureVisible(find.byTooltip('Cloud account'));
    await tester.tap(find.byTooltip('Cloud account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete cloud account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(cloudApi.accountDeletions, 0);
    expect(controller.narration!.manifest.cloudBookId, isNotNull);
    await tester.tap(find.byTooltip('Cloud account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete cloud account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(cloudApi.accountDeletions, 1);
    expect(controller.catalog.books.single.lastPosition, anchor);
    expect(controller.narration!.manifest.cloudBookId, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narration controls visual baseline', (tester) async {
    final book = testBook(), documents = MemoryDocumentStore();
    final source = FixtureLocalNarrationSource();
    final api = FakeNarrationApi();
    final controller = ReaderController(
      catalogStore: MemoryCatalogStore([book]),
      settingsStore: MemorySettingsStore(),
      importer: BookImporter(root: Directory.systemTemp),
      picker: FakePicker([]),
      illustrationApi: FakeIllustrationApi(),
      illustrationStore: MemoryIllustrationStore(),
      wordCounter: FakeWordCounter(),
      narrationApi: api,
      narrationSource: source,
      narrationPlayer: FakeNarrationPlayer(),
      narrationStore: MemoryNarrationStore(),
      narrationDocuments: documents,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await disposeControllerWithFrames(tester, controller);
    });
    await controller.initialize();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildReaderTheme(ReadingTheme.paper),
        home: ReaderScreen(
          book: book,
          controller: controller,
          documentStore: documents,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Listen'));
    await tester.pumpAndSettle();
    expect(api.registrations, 0);
    expect(source.renders, 0);
    expect(controller.preferences.settings.narrationVoice, source.defaultVoice);
    expect(find.byTooltip('Cloud account'), findsNothing);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/narration_controls.png'),
    );
  });
}
