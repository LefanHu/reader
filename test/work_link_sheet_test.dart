import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/catalog_works/work_link_coordinator.dart';
import 'package:reader/reader/work_link_sheet.dart';
import 'package:reader/text/text_block.dart';
import 'package:reader/text/text_section.dart';

import 'support/fake_works_api.dart';
import 'support/memory_document_store.dart';

final _book = CatalogBook(
  wordCount: 0,
  hash: 'b' * 64,
  fileName: 'emma.epub',
  path: 'emma.epub',
  title: 'Emma',
  authors: const ['Jane Austen'],
  addedAt: DateTime.utc(2026),
);

final _documents = MemoryDocumentStore(
  sections: const [
    TextSection(
      id: 's0',
      blocks: [
        TextBlock(
          id: 'b',
          text: 'Emma Woodhouse, handsome, clever, and rich, with a comfortable home.',
        ),
      ],
    ),
  ],
);

void main() {
  late Directory root;
  late FakeWorksApi api;
  late WorkLinkCoordinator works;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('work_link_sheet');
    api = FakeWorksApi();
    works = WorkLinkCoordinator(
      api: api,
      root: root,
      account: () => 'reader@example.test',
      changed: () {},
      documents: _documents,
    );
  });
  tearDown(() => root.delete(recursive: true));

  /// Lets real file IO and fake API calls finish, rebuilding between steps;
  /// the progress bar animates while busy, so pumpAndSettle cannot be used.
  Future<void> settle(WidgetTester tester) async {
    for (var step = 0; step < 20; step++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkLinkSheet(works: works, book: _book),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('searches with the book title and links an indexed work', (
    tester,
  ) async {
    api.addToIndex('Emma', author: 'Jane Austen', year: 1815);
    await open(tester);
    expect(api.calls, ['current', 'search:Emma Jane Austen']);
    expect(find.text('Jane Austen · 1815'), findsOneWidget);
    await tester.tap(find.text('Emma'));
    await settle(tester);
    expect(api.calls.last, 'link:Emma');
    expect(find.text('Linked to Emma by Jane Austen'), findsOneWidget);
    expect(find.text('100% of paragraphs match'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.text('Unlink'));
    await settle(tester);
    expect(find.textContaining('Linked to'), findsNothing);
  });

  testWidgets('a copy that does not match the reference reports it inline', (
    tester,
  ) async {
    final work = api.addToIndex('Emma', author: 'Jane Austen');
    api.references[work.id] = 'another copy';
    await open(tester);
    expect(find.text('Jane Austen · In catalog'), findsOneWidget);
    await tester.tap(find.text('Emma'));
    await settle(tester);
    expect(
      find.textContaining("doesn't match the catalog's copy"),
      findsOneWidget,
    );
    expect(find.textContaining('Linked to'), findsNothing);
  });

  testWidgets('a book the index lacks links under the file metadata', (
    tester,
  ) async {
    api.degraded = true;
    await open(tester);
    expect(find.textContaining('No books match'), findsOneWidget);
    expect(find.textContaining('book index is unreachable'), findsOneWidget);
    await tester.tap(find.text("Use this file's title and author"));
    await settle(tester);
    expect(api.calls.last, 'link:Emma');
    expect(find.text('Linked to Emma by Jane Austen'), findsOneWidget);
  });
}
