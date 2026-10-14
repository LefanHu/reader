import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/catalog_works/work_text.dart';
import 'package:reader/text/text_block.dart';
import 'package:reader/text/text_section.dart';

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
        expect(normalizeWorkParagraph(text), item['normalized'], reason: text);
        expect(
          _hex(workParagraphFingerprint(text)),
          item['fingerprint'],
          reason: text,
        );
      }
    },
  );

  test(
    'book text fingerprints every block in reading order and counts sections',
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
      final text = await buildWorkText('book.epub', documents: documents);
      expect(text.sectionCount, 2);
      expect(text.fingerprints.length, 3 * workFingerprintBytes);
      expect(text.fingerprints.sublist(0, 8), everyElement(0));
      expect(
        text.fingerprints.sublist(8, 16),
        workParagraphFingerprint('It was a bright cold day in April.'),
      );
      expect(
        text.fingerprints.sublist(16),
        workParagraphFingerprint('And the clocks were striking thirteen.'),
      );
    },
  );
}
