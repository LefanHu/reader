import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/importing/book_importer.dart';
import 'package:reader/app/reader_controller.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/preferences/reading_theme.dart';
import 'package:reader/narration/session.dart';
import 'package:reader/reader/reader_screen.dart';
import 'package:reader/theme.dart';
import 'package:reader/text/text_block.dart' as text;
import 'package:reader/text/text_position.dart' as text;
import 'package:reader/text/text_section.dart' as text;
import 'package:reader/text/viewport.dart';

import 'fixtures/catalog_book.dart';
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
    'Listen consent cancels without sign-in or prose; hidden button loses semantics',
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
        narrationPlayer: player,
        narrationStore: MemoryNarrationStore(),
        narrationDocuments: documents,
      );
      await controller.initialize();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await tester.pumpAndSettle();
        await controller.flush();
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
      expect(find.text('Listen with AI narration?'), findsOneWidget);
      expect(api.registrations, 0);
      expect(api.requests, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.registrations, 0);
      expect(api.requests, isEmpty);
      final semantics = tester.ensureSemantics();

      await tester.tap(find.byTooltip('Hide reading controls'));
      await tester.pump();
      expect(find.bySemanticsLabel('Listen'), findsNothing);
      semantics.dispose();
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
        narrationPlayer: player,
        narrationStore: MemoryNarrationStore(),
        narrationDocuments: documents,
      );
      await controller.initialize();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await tester.pumpAndSettle();
        await controller.flush();
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
      await controller.consentToNarration(book);
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

  testWidgets('narration controls visual baseline', (tester) async {
    final book = testBook(), documents = MemoryDocumentStore();
    final controller = ReaderController(
      catalogStore: MemoryCatalogStore([book]),
      settingsStore: MemorySettingsStore(),
      importer: BookImporter(root: Directory.systemTemp),
      picker: FakePicker([]),
      illustrationApi: FakeIllustrationApi(),
      illustrationStore: MemoryIllustrationStore(),
      wordCounter: FakeWordCounter(),
      narrationApi: FakeNarrationApi(),
      narrationPlayer: FakeNarrationPlayer(),
      narrationStore: MemoryNarrationStore(),
      narrationDocuments: documents,
    );
    await controller.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.pumpAndSettle();
      await controller.flush();
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
    await controller.consentToNarration(book);
    await tester.tap(find.byTooltip('Listen'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/narration_controls.png'),
    );
    await controller.narration!.play();
    await tester.pump();
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
    final api = controller.narration!.api as FakeNarrationApi;
    final anchor = controller.catalog.books.single.lastPosition;
    await tester.tap(find.byTooltip('Cloud account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete cloud account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.accountDeletions, 0);
    expect(controller.narration!.manifest.cloudBookId, isNotNull);
    await tester.tap(find.byTooltip('Cloud account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete cloud account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(api.accountDeletions, 1);
    expect(controller.catalog.books.single.lastPosition, anchor);
    expect(controller.narration!.manifest.cloudBookId, isNull);
    expect(find.text('AI narration'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
