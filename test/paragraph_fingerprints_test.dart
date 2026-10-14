import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/text/text_block.dart';
import 'package:reader/text/text_section.dart';
import 'package:reader/text_identity/paragraph_fingerprints.dart';

import 'support/memory_document_store.dart';

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test(
    'normalization and fingerprints match the golden shared with the server',
    () {
      final golden = jsonDecode(
        File('backend/test-fixtures/fingerprints.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      for (final item in (golden['cases'] as List).cast<Map>()) {
        final text = item['text'] as String;
        expect(normalizeParagraph(text), item['normalized'], reason: text);
        expect(
          _hex(paragraphFingerprint(text)),
          item['fingerprint'],
          reason: text,
        );
      }
    },
  );

  test(
    'book fingerprints cover every block in reading order and counts sections',
    () async {
      final documents = MemoryDocumentStore(
        sections: const [
          TextSection(
            id: 's0',
            blocks: [
              TextBlock(id: 'a', text: 'Chapter 1'),
              TextBlock(id: 'b', text: 'It was a bright cold day in April.'),
            ],
          ),
          TextSection(
            id: 's1',
            blocks: [
              TextBlock(
                id: 'c',
                text: 'And the clocks were striking thirteen.',
              ),
            ],
          ),
        ],
      );
      final book = await buildBookFingerprints(
        'book.epub',
        documents: documents,
      );
      expect(book.sectionCount, 2);
      expect(book.fingerprints.length, 3 * fingerprintBytes);
      expect(book.fingerprints.sublist(0, 8), everyElement(0));
      expect(
        book.fingerprints.sublist(8, 16),
        paragraphFingerprint('It was a bright cold day in April.'),
      );
      expect(
        book.fingerprints.sublist(16),
        paragraphFingerprint('And the clocks were striking thirteen.'),
      );
    },
  );
}
