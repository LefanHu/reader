import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:reader/book_service.dart';

import 'fixtures/epub.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/models.dart';
import 'package:reader/text/document.dart';
import 'package:reader/text/word_count.dart';

import 'fakes.dart';

/// Controls worker completion to verify merges against live catalog records.
class _DelayedCounter implements BookWordCounter {
  final pending = <Completer<int>>[];
  @override
  Future<int> count(String sourcePath) {
    final result = Completer<int>();
    pending.add(result);
    return result.future;
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'estimates multilingual runs without counting marks or emoji as words',
    () {
      for (final (text, count) in [
        ('Hello world 123', 3),
        ("don't l’amour rock''roll", 4),
        ('العربية جميلة', 2),
        ('שָׁלוֹם עולם', 2),
        ('हिन्दी भाषा', 2),
        ('ภาษาไทย', 1),
        ('中文 あいう アイウ', 8),
        ('e\u0301 cafe\u0301', 2),
        ('\u0301 … — 👩🏽‍🚀 🙂 1️⃣ ℹ️', 0),
        ('𠀀か\u3099 ｶﾞ', 3),
      ]) {
        expect(approximateWordCount(text), count, reason: text);
      }
      expect(wordCountLabel(52430), '≈ 52,430 words');
    },
  );

  test('imports store the same estimate as normalized section backfill for EPUB and TXT', () async {
    final root = await Directory.systemTemp.createTemp('reader_word_count');
    addTearDown(() => root.delete(recursive: true));
    final importer = BookImporter(root: root);
    for (final (name, bytes) in [
      ('Book.epub', epubFixture()),
      (
        'Book.txt',
        Uint8List.fromList(
          utf8.encode("Hello 中文 e\u0301 👩🏽‍🚀\n\nالعربية جميلة"),
        ),
      ),
    ]) {
      final result = await importer.import(
        ImportCandidate(
          name: name,
          size: bytes.length,
          readBytes: () async => bytes,
        ),
        {},
      );
      expect(result.result.status, ImportStatus.imported);
      final book = result.book!;
      expect(book.wordCount, greaterThan(0));
      expect(await FileBookWordCounter().count(book.path), book.wordCount);
      // Backfill only consumes normalized text, never reparses a source file.
      await File(book.path).delete();
      expect(await FileBookWordCounter().count(book.path), book.wordCount);
    }
  });

  test('counts headings and paragraphs once with block boundaries', () {
    expect(
      countSectionWords(
        const TextSection(
          id: 's0',
          blocks: [
            TextBlock(id: 'h', kind: 'heading', text: 'A heading'),
            TextBlock(id: 'p', text: '中文 two words'),
          ],
        ),
      ),
      6,
    );
  });

  test(
    'word counts persist and survive reading updates without a migration',
    () {
      final book = testBook().copyWith(wordCount: 52430);
      final restored = CatalogBook.fromJson(book.toJson());
      final updated = restored.copyWith(
        progress: .5,
        lastPosition: const TextPosition(
          sectionId: 's0',
          blockId: 'p0',
          offset: 8,
        ),
      );
      expect(updated.wordCount, 52430);
      expect(updated.lastPosition?.offset, 8);
      expect(CatalogBook.fromJson(testBook().toJson()).wordCount, isNull);
      expect(
        CatalogBook.fromJson({...book.toJson(), 'wordCount': -1}).wordCount,
        isNull,
      );
    },
  );

  test(
    'backfill merges current reading state and saves the completed count',
    () async {
      final counter = _DelayedCounter();
      final controller = await testController(
        books: [testBook()],
        wordCounter: counter,
      );
      addTearDown(controller.dispose);
      expect(counter.pending, hasLength(1));
      await controller.markOpened(controller.books.single);
      await controller.savePosition(
        controller.books.single,
        const TextPosition(sectionId: 's0', blockId: 'p0', offset: 8),
        .5,
      );
      final opened = controller.books.single.lastOpenedAt;
      counter.pending.single.complete(100);
      await _settle();
      expect(controller.books.single.wordCount, 100);
      expect(controller.books.single.lastOpenedAt, opened);
      expect(controller.books.single.lastPosition?.offset, 8);
      expect(controller.books.single.progress, .5);
      expect(
        (controller.catalogStore as MemoryCatalogStore).books.single.wordCount,
        100,
      );
    },
  );

  test(
    'opening through a stale UI record preserves a backfilled count',
    () async {
      final original = testBook();
      final controller = await testController(books: [original]);
      addTearDown(controller.dispose);
      await _settle();
      expect(controller.books.single.wordCount, 42);
      await controller.markOpened(original);
      expect(controller.books.single.wordCount, 42);
    },
  );

  test('deletion during counting never resurrects a book', () async {
    final counter = _DelayedCounter();
    final controller = await testController(
      books: [testBook()],
      wordCounter: counter,
    );
    addTearDown(controller.dispose);
    await controller.delete(controller.books.single);
    counter.pending.single.complete(100);
    await _settle();
    expect(controller.books, isEmpty);
    expect((controller.catalogStore as MemoryCatalogStore).books, isEmpty);
  });

  test(
    'interrupted backfill stays missing and retries after restart',
    () async {
      final counter = _DelayedCounter();
      final controller = await testController(
        books: [testBook()],
        wordCounter: counter,
      );
      final store = controller.catalogStore as MemoryCatalogStore;
      controller.dispose();
      counter.pending.single.complete(100);
      await _settle();
      expect(store.books.single.wordCount, isNull);
      final restarted = await testController(books: store.books);
      addTearDown(restarted.dispose);
      await _settle();
      expect(restarted.books.single.wordCount, 42);
    },
  );

  test(
    'backfill is sequential and a failed count does not stop later books',
    () async {
      final counter = _DelayedCounter();
      final second = CatalogBook(
        hash: 'b' * 64,
        fileName: 'b.txt',
        path: '/b.txt',
        title: 'B',
        authors: const [],
        addedAt: DateTime.utc(2026),
      );
      final controller = await testController(
        books: [testBook(), second],
        wordCounter: counter,
      );
      addTearDown(controller.dispose);
      expect(counter.pending, hasLength(1));
      counter.pending.first.completeError(
        const FormatException('Missing section'),
      );
      await _settle();
      expect(counter.pending, hasLength(2));
      expect(controller.books.first.wordCount, isNull);
      counter.pending.last.complete(5);
      await _settle();
      expect(controller.books.last.wordCount, 5);
    },
  );
}
