import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/illustrations/document_text_indexer.dart';
import 'package:reader/importing/book_importer.dart';
import 'package:reader/importing/import_candidate.dart';
import 'package:reader/importing/import_result.dart';
import 'package:reader/text/direction.dart';
import 'package:reader/text/document_store.dart' as text;
import 'package:reader/text/grapheme_boundary.dart' as text;
import 'package:reader/text/parsed_text_book.dart';
import 'package:reader/text/parser.dart';
import 'package:reader/text/parser_limits.dart';

import 'fixtures/epub.dart';

void main() {
  ParsedTextBook parseTxt(String value) =>
      parseTextBook(Uint8List.fromList(utf8.encode(value)), 'Book.txt', 'hash');
  test('EPUB retains metadata nested navigation and explicit line breaks', () {
    final parsed = parseTextBook(epubFixture(), 'book.epub', 'hash');
    expect(parsed.document.title, 'Novel');
    expect(parsed.document.authors, ['Writer']);
    expect(parsed.document.identifier, 'test-id');
    expect(parsed.sections.single.blocks.last.text, 'مرحبا بالعالم\n第二行');
    expect(parsed.sections.single.blocks.last.direction, 'rtl');
    expect(
      parsed.document.contents.single.children.single.position!.blockId,
      parsed.sections.single.blocks.last.id,
    );
  });
  test(
    'nested text blocks are extracted once and omitted content stays absent',
    () {
      final parsed = parseTextBook(
        epubFixture(
          body: '<div>Before<p>Inside <em>emphasis</em></p>After</div><blockquote><p>Quote</p></blockquote><ul><li>First<ul><li>Nested</li></ul>Last</li></ul><p hidden="hidden">Hidden</p><img src="local.png" alt="image"/>',
        ),
        'book.epub',
        'hash',
      );
      expect(parsed.sections.single.blocks.map((b) => b.text), [
        'Before',
        'Inside emphasis',
        'After',
        'Quote',
        'First',
        'Nested',
        'Last',
      ]);
    },
  );
  test(
    'TXT accepts UTF-8 BOM and both strict BOM-marked UTF-16 byte orders',
    () {
      const value = '中文 العربية 👩🏽‍🚀';
      final encodings = [
        Uint8List.fromList([0xef, 0xbb, 0xbf, ...utf8.encode(value)]),
        Uint8List.fromList([
          0xff,
          0xfe,
          for (final c in value.codeUnits) ...[c & 255, c >> 8],
        ]),
        Uint8List.fromList([
          0xfe,
          0xff,
          for (final c in value.codeUnits) ...[c >> 8, c & 255],
        ]),
      ];
      for (final bytes in encodings) {
        expect(
          parseTextBook(
            bytes,
            'Book.txt',
            'hash',
          ).sections.single.blocks.single.text,
          value,
        );
      }
      for (final bytes in [
        [0xff],
        [0xff, 0xfe, 0x00, 0xd8],
        [0xff, 0xfe, 0],
        [65, 0, 66, 0],
      ]) {
        expect(
          () => parseTextBook(Uint8List.fromList(bytes), 'Book.txt', 'hash'),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'TXT boundaries and oversized blocks are deterministic and grapheme safe',
    () {
      final source = 'e\u0301👩🏽‍🚀' * 4000;
      final first = parseTxt('$source\n\nNext\fFinal');
      final second = parseTxt('$source\n\nNext\fFinal');
      final pieces = first.sections.first.blocks
          .take(first.sections.first.blocks.length - 1)
          .map((block) => block.text)
          .toList();
      expect(pieces.join(), source);
      expect(pieces.every((part) => part.length <= maxBlockCharacters), isTrue);
      expect(pieces.expand((part) => part.characters), source.characters);
      expect(first.document.toJson(), second.document.toJson());
      expect(first.sections, hasLength(2));
    },
  );
  test('large TXT sections respect every illustration API bound', () {
    final parsed = parseTxt(
      List.generate(2101, (i) => 'Paragraph $i').join('\n\n'),
    );
    expect(parsed.sections, hasLength(2));
    for (final section in parsed.sections) {
      expect(section.blocks.length, lessThanOrEqualTo(2000));
      expect(section.length, lessThanOrEqualTo(maxSectionCharacters));
    }
    final large = parseTxt('中' * 410000);
    expect(large.sections, hasLength(2));
    expect(
      large.sections.expand((s) => s.blocks).map((b) => b.text).join(),
      '中' * 410000,
    );
  });
  test('EPUB trust boundaries reject traversal scripts fixed layout and remote assets', () {
    final fixtures = [
      epubFixture(extra: '../escape'),
      epubFixture(body: '<script>alert(1)</script><p>Text</p>'),
      epubFixture(body: '<p onclick="x()">Text</p>'),
      epubFixture(
        metadata: '<meta property="rendition:layout">pre-paginated</meta>',
      ),
      epubFixture(
        manifestExtra: '<item id="remote" href="https://example.com/image.jpg" media-type="image/jpeg"/>',
      ),
      epubFixture(body: '<p>Text</p><img src="//example.com/image.jpg"/>'),
    ];
    for (final bytes in fixtures) {
      expect(
        () => parseTextBook(bytes, 'book.epub', 'hash'),
        throwsFormatException,
      );
    }
    expect(() => parseTxt(' \n\n '), throwsFormatException);
  });
  test('archive expansion and markup limits run before extraction', () {
    final archive = Archive()
      ..addFile(ArchiveFile.string('bomb.txt', 'a' * (2 * 1024 * 1024)));
    expect(
      () => parseTextBook(
        Uint8List.fromList(ZipEncoder().encode(archive)),
        'bomb.epub',
        'hash',
      ),
      throwsFormatException,
    );
  });
  test(
    'Unicode first-strong detection ignores punctuation and combining marks',
    () {
      expect(paragraphDirection('123 — مرحبا English'), TextDirection.rtl);
      expect(paragraphDirection('\u0301中文 العربية'), TextDirection.ltr);
      expect(paragraphDirection('שָׁלוֹם'), TextDirection.rtl);
      expect(
        paragraphDirection('\u{10D50}'),
        TextDirection.rtl,
      ); // Garay, added in Unicode 16.
      expect(paragraphDirection('हिन्दी ไทย'), TextDirection.ltr);
      expect(paragraphDirection('English', 'rtl'), TextDirection.rtl);
      expect(paragraphDirection('🙂 123'), TextDirection.ltr);
      expect(text.graphemeFloor('e\u0301👩🏽‍🚀x', 3), 2);
    },
  );
  test(
    'normalized rendering and illustration prose use identical blocks and IDs',
    () async {
      final root = await Directory.systemTemp.createTemp('document_prose');
      addTearDown(() => root.delete(recursive: true));
      final bytes = Uint8List.fromList(
        utf8.encode('Arabic العربية\n\n中文\fहिन्दी'),
      );
      final outcome = await BookImporter(root: root).import(
        ImportCandidate(
          name: 'Book.txt',
          size: bytes.length,
          readBytes: () async => bytes,
        ),
        {},
      );
      expect(outcome.result.status, ImportStatus.imported);
      final book = outcome.book!;
      final index = await DocumentTextIndexer().index(
        sourcePath: book.path,
        bookHash: book.hash,
      );
      final store = text.TextDocumentStore();
      final document = await store.load(book.path);
      for (var i = 0; i < document.sections.length; i++) {
        final section = await store.loadSection(
          book.path,
          document.sections[i].id,
        );
        expect(
          index.chapters[i].paragraphs.map((p) => p.text),
          section.blocks.map((b) => b.text),
        );
        expect(
          index.chapters[i].paragraphs.map((p) => p.id),
          section.blocks.map((b) => b.id),
        );
      }
    },
  );
}
