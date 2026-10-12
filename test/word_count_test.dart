import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:reader/importing/book_importer.dart';
import 'package:reader/importing/import_candidate.dart';

import 'fixtures/epub.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/importing/import_result.dart';
import 'package:reader/text/text_block.dart';
import 'package:reader/text/text_position.dart';
import 'package:reader/text/text_section.dart';
import 'package:reader/text/word_count.dart';
import 'package:reader/text/word_count_label.dart';

import 'fixtures/catalog_book.dart';

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

  test('imports store a positive word count for EPUB and TXT', () async {
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

  test('word counts persist and survive reading updates', () {
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
  });
}
