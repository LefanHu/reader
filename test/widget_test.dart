import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/importing/book_importer.dart';
import 'package:reader/app/reader_controller.dart';
import 'package:reader/library/library_screen.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/preferences/reader_settings.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/reader/reader_screen.dart';
import 'package:reader/text/grapheme_boundary.dart' as text;
import 'package:reader/text/text_block.dart' as text;
import 'package:reader/text/text_contents_entry.dart' as text;
import 'package:reader/text/text_position.dart' as text;
import 'package:reader/text/text_section.dart' as text;
import 'package:reader/text/reader_navigation.dart';
import 'package:reader/text/viewport.dart';
import 'package:reader/theme.dart';

import 'fixtures/catalog_book.dart';
import 'support/fake_illustration_api.dart';
import 'support/fake_picker.dart';
import 'support/fake_text_indexer.dart';
import 'support/memory_catalog_store.dart';
import 'support/memory_document_store.dart';
import 'support/memory_illustration_store.dart';
import 'support/memory_settings_store.dart';
import 'support/test_controller.dart';

void main() {
  testWidgets('empty library offers EPUB and TXT import', (tester) async {
    final controller = await testController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: readerTheme,
        home: LibraryScreen(controller: controller),
      ),
    );
    expect(find.text('Your shelf is ready'), findsOneWidget);
    expect(find.text('Import books'), findsWidgets);
  });

  testWidgets('library searches filters and deletes books', (tester) async {
    final reading = testBook(
      position: const text.TextPosition(sectionId: 's0', blockId: 'p0'),
      progress: .4,
    );
    final second = CatalogBook(
      hash: 'b' * 64,
      fileName: 'z.txt',
      path: '/tmp/z.txt',
      title: 'Another Book',
      authors: const ['Zed'],
      progress: 1,
      addedAt: DateTime.utc(2025),
    );
    final controller = await testController(books: [reading, second]);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: readerTheme.copyWith(platform: TargetPlatform.iOS),
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
    expect(find.text('Test Book'), findsNothing);
    await tester.ensureVisible(find.byTooltip('Book actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Book actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(controller.catalog.books, hasLength(1));
  });

  testWidgets(
    'real reader restores text changes mode and navigates nested contents',
    (tester) async {
      final store = MemoryDocumentStore(
        contents: const [
          text.TextContentsEntry(
            title: 'Part',
            children: [
              text.TextContentsEntry(
                title: 'Nested passage',
                position: text.TextPosition(sectionId: 's0', blockId: 'p1'),
              ),
            ],
          ),
        ],
      );
      final book = testBook(
        position: const text.TextPosition(
          sectionId: 's0',
          blockId: 'p0',
          offset: 2,
        ),
      );
      final controller = await testController(books: [book]);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: readerTheme,
          home: ReaderScreen(
            book: book,
            controller: controller,
            documentStore: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.catalog.books.single.lastPosition!.offset, 2);
      await tester.tap(find.byTooltip('Reading settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pages'));
      await tester.pumpAndSettle();
      expect(controller.preferences.settings.mode, ReadingMode.pages);
      await tester.tap(find.byTooltip('Close settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Choose chapter'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nested passage'));
      await tester.pumpAndSettle();
      expect(controller.catalog.books.single.lastPosition!.blockId, 'p1');
      await tester.tap(find.byTooltip('Hide reading controls'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Show reading controls'), findsOneWidget);
      expect(controller.catalog.books.single.lastPosition!.blockId, 'p1');
      await tester.tap(find.byTooltip('Show reading controls'));
      await tester.pumpAndSettle();
      expect(controller.catalog.books.single.lastPosition!.blockId, 'p1');
    },
  );

  testWidgets(
    'multilingual pagination preserves grapheme anchors through reflow',
    (tester) async {
      const phrase = '中文 العربية שָׁלוֹם हिन्दी ไทย e\u0301 👩🏽‍🚀 ';
      final block = text.TextBlock(id: 'p0', text: phrase * 60);
      final store = MemoryDocumentStore(
        sections: [
          text.TextSection(id: 's0', blocks: [block]),
        ],
      );
      final navigation = TextReaderNavigation();
      final settings = ValueNotifier(
        const ReaderSettings(mode: ReadingMode.pages),
      );
      addTearDown(settings.dispose);
      var size = const Size(350, 260);
      final semantics = tester.ensureSemantics();

      Widget app() => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: ValueListenableBuilder(
                valueListenable: settings,
                builder: (_, value, _) => TextViewport(
                  document: store.document,
                  sourcePath: '/memory/book',
                  store: store,
                  navigation: navigation,
                  settings: value,
                  foreground: Colors.black,
                  onPosition: (_, _, _) {},
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        navigation.next();
        await tester.pumpAndSettle();
      }
      final anchor = navigation.leadingPosition!;
      expect(anchor.offset, greaterThan(0));
      expect(text.graphemeFloor(block.text, anchor.offset), anchor.offset);
      settings.value = settings.value.copyWith(fontSize: 150, serif: false);
      await tester.pumpAndSettle();
      expect(navigation.leadingPosition, anchor);
      size = const Size(500, 300);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(navigation.leadingPosition, anchor);
      settings.value = settings.value.copyWith(mode: ReadingMode.scroll);
      await tester.pumpAndSettle();
      expect(navigation.leadingPosition, anchor);
      expect(navigation.retainedLayoutCount, lessThanOrEqualTo(2));
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'page painting semantics retain every character across boundaries',
    (tester) async {
      final value = 'مرحبا 中文 e\u0301 👩🏽‍🚀 line\n' * 25;
      final store = MemoryDocumentStore(
        sections: [
          text.TextSection(
            id: 's0',
            blocks: [text.TextBlock(id: 'p0', text: value)],
          ),
        ],
      );
      final navigation = TextReaderNavigation();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 230,
              child: TextViewport(
                document: store.document,
                sourcePath: '/memory',
                store: store,
                navigation: navigation,
                settings: const ReaderSettings(mode: ReadingMode.pages),
                foreground: Colors.black,
                onPosition: (_, _, _) {},
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final pieces = <String>[];
      for (var i = 0; i < 100; i++) {
        pieces.addAll(
          tester
              .widgetList<Semantics>(
                find.descendant(
                  of: find.byType(TextViewport),
                  matching: find.byType(Semantics),
                ),
              )
              .map((w) => w.properties.label)
              .whereType<String>(),
        );
        final before = navigation.leadingPosition;
        navigation.next();
        await tester.pumpAndSettle();
        final after = navigation.leadingPosition;
        if (after!.offset == value.length || after == before) break;
        expect(text.graphemeFloor(value, after.offset), after.offset);
      }
      expect(pieces.join(), value);
    },
  );

  testWidgets(
    'keyboard navigation advances logical RTL pages and can finish a book',
    (tester) async {
      final store = MemoryDocumentStore(
        sections: [
          text.TextSection(
            id: 's0',
            blocks: [
              text.TextBlock(
                id: 'p0',
                text: 'مرحبا بالعالم ' * 40,
                direction: 'rtl',
              ),
            ],
          ),
        ],
      );
      final navigation = TextReaderNavigation();
      var progress = 0.0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 220,
              child: TextViewport(
                document: store.document,
                sourcePath: '/memory',
                store: store,
                navigation: navigation,
                settings: const ReaderSettings(mode: ReadingMode.pages),
                foreground: Colors.black,
                onPosition: (_, p, _) => progress = p,
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(navigation.leadingPosition!.offset, greaterThan(0));
      for (var i = 0; i < 100 && progress < 1; i++) {
        navigation.next();
        await tester.pumpAndSettle();
      }
      expect(progress, 1);
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
      importer: BookImporter(root: Directory.systemTemp),
      picker: FakePicker(),
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
          documentStore: MemoryDocumentStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('AI illustrations'));
    await tester.pumpAndSettle();
    expect(find.text('Illustrate this book?'), findsOneWidget);
    expect(api.createdChapterOrdinals, isEmpty);
    await tester.tap(find.text('Enable illustrations'));
    await tester.pumpAndSettle();
    expect(api.createdChapterOrdinals, [0]);
  });
}
