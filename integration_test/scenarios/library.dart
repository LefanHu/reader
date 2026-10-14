import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:reader/text/word_count.dart';
import 'package:reader/text/word_count_label.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/catalog_works/work_text.dart';
import 'package:reader/preferences/reading_theme.dart';
import 'package:reader/text/document_store.dart';
import 'package:reader/theme.dart';

import '../../test/support/cloud_identity_fake.dart';
import '../../test/support/fake_works_api.dart';
import '../support/native_test_app.dart';

/// Registers independent offline import and application appearance scenarios.
void registerLibraryTests() {
  testWidgets('imports EPUB and TXT through the library action', (
    tester,
  ) async {
    final app = await NativeTestApp.launch(tester, importBooks: false);
    await app.importThroughLibrary();
    expect(app.controller.catalog.books, hasLength(2));
    expect(find.text('Import results'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    for (final title in ['Unicode Test', 'Novel']) {
      final book = app.book(title);
      expect(await File(book.path).exists(), isTrue);
      final document = await TextDocumentStore().load(book.path);
      expect(document.title, title);
      expect(document.sections, isNotEmpty);
      var words = 0;
      for (final section in document.sections) {
        words += countSectionWords(
          await TextDocumentStore().loadSection(book.path, section.id),
        );
      }
      expect(book.wordCount, words);
    }
  });

  testWidgets(
    'platform library shows readable counts and independent book actions',
    (tester) async {
      final app = await NativeTestApp.launch(tester);
      final book = app.book('Unicode Test');
      final entry = find.byKey(ValueKey('library-book-${book.hash}'));
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      final bounds = tester.getRect(entry);
      if (Platform.isMacOS) {
        expect(find.byType(SliverGrid), findsOneWidget);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        try {
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(bounds.center);
          await tester.pumpAndSettle();
          expect(tester.getRect(entry), bounds);
          expect(
            find.descendant(
              of: entry,
              matching: find.text(wordCountLabel(book.wordCount)),
            ),
            findsOneWidget,
          );
          await app.capture('library-hover');
          await tester.tap(
            find.descendant(
              of: entry,
              matching: find.byTooltip('Book actions'),
            ),
          );
          await tester.pumpAndSettle();
          await mouse.moveTo(Offset.zero);
          await tester.pumpAndSettle();
          expect(find.text('Delete'), findsOneWidget);
        } finally {
          await mouse.removePointer();
        }
      } else {
        expect(find.byType(SliverGrid), findsNothing);
        expect(find.byType(SliverList), findsOneWidget);
        expect(find.text(wordCountLabel(book.wordCount)), findsOneWidget);
        await app.capture('library-list');
        await tester.tap(
          find.descendant(of: entry, matching: find.byTooltip('Book actions')),
        );
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete book?'), findsOneWidget);
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      expect(
        app.controller.catalog.books.any((item) => item.hash == book.hash),
        isFalse,
      );
    },
  );

  testWidgets('links a book to the shared catalog and unlinks it', (
    tester,
  ) async {
    final works = FakeWorksApi()
      ..addToIndex('Unicode Test', author: 'Index Author', year: 1901);
    final app = await NativeTestApp.launch(
      tester,
      cloudIdentity: FakeCloudIdentity()..email = 'reader@example.test',
      worksApi: works,
    );
    final book = app.book('Unicode Test');
    final entry = find.byKey(ValueKey('library-book-${book.hash}'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: entry, matching: find.byTooltip('Book actions')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Book catalog…'));
    await tester.pumpAndSettle();
    expect(works.calls, ['current', 'search:Unicode Test']);
    expect(find.text('Index Author · 1901'), findsOneWidget);

    await tester.tap(find.text('Index Author · 1901'));
    await tester.pumpAndSettle();
    expect(find.text('Linked to Unicode Test by Index Author'), findsOneWidget);
    final link = app.controller.works!.linkFor(book)!;
    // The real normalized sidecars were read: whole fingerprints, no text.
    final sent = base64Decode(works.references[link.work.id]!);
    expect(sent, isNotEmpty);
    expect(sent.length % workFingerprintBytes, 0);
    expect(
      File('${app.root.path}/work-links.json').readAsStringSync(),
      contains(link.work.id),
    );

    await tester.tap(find.text('Unlink'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Linked to'), findsNothing);
    expect(app.controller.works!.linkFor(book), isNull);
  });

  for (final preset in ReadingTheme.values) {
    testWidgets(
      'appearance menu applies ${preset.name} throughout the library',
      (tester) async {
        final app = await NativeTestApp.launch(tester);
        await tester.tap(find.byTooltip('Appearance'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(themeLabel(preset)));
        await tester.pumpAndSettle();
        expect(app.controller.preferences.settings.theme, preset);
        expect(
          Theme.of(tester.element(find.text('Your library'))).colorScheme,
          buildReaderTheme(preset).colorScheme,
        );
        await app.capture('library-${preset.name}');
      },
    );
  }
}
