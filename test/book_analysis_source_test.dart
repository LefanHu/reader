import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/book_analysis/analysis_source.dart';
import 'package:reader/book_analysis/analysis_source_models.dart';
import 'package:reader/book_analysis/analysis_span.dart';
import 'package:reader/book_analysis/analysis_limits.dart';
import 'package:reader/importing/book_importer.dart';
import 'package:reader/importing/import_candidate.dart';
import 'package:reader/text/document.dart';
import 'package:reader/text/document_store.dart';
import 'package:reader/text/grapheme_boundary.dart';
import 'package:reader/text/section_summary.dart';
import 'package:reader/text/text_block.dart';
import 'package:reader/text/text_position.dart';
import 'package:reader/text/text_section.dart';

void main() {
  test(
    'the default disk source builds the same manifest on a background isolate',
    () async {
      final root = await Directory.systemTemp.createTemp('analysis_source');
      addTearDown(() => root.delete(recursive: true));
      final bytes = Uint8List.fromList(
        utf8.encode('${'Mara walks e\u0301 and 👩🏽‍🚀. ' * 400}\n\nThe end.'),
      );
      final imported = await BookImporter(root: root).import(
        ImportCandidate(
          name: 'Book.txt',
          size: bytes.length,
          readBytes: () async => bytes,
        ),
        {},
      );
      final path = imported.book!.path;
      final background = await AnalysisSource().buildManifest(path);
      final inline = await AnalysisSource(documents: TextDocumentStore())
          .buildManifest(path);
      expect(background.documentDigest, inline.documentDigest);
      expect(background.chunkCount, inline.chunkCount);
      expect(background.chunkCount, greaterThan(0));
    },
  );

  test('combining accents emoji and newline share the Node hash golden', () {
    expect(
      analysisSpanHash(
        sectionOrdinal: 0,
        sectionId: 's',
        blockOrdinal: 0,
        blockId: 'b',
        startOffset: 0,
        endOffset: 5,
        text: 'e\u0301😀\n',
      ),
      '5380d185b9087be7937b2ee1ce4c0e2ee659a0fe3684ec10c0e858bee725dfa0',
    );
  });

  test(
    'every section and block is covered once with untouched source text',
    () async {
      final large = '${'a' * 5999}e\u0301😀\n${'z' * 7500}';
      final store = _SourceStore([
        TextSection(
          id: 's0',
          blocks: [
            const TextBlock(id: 'empty', text: ''),
            TextBlock(id: 'long', text: large),
            const TextBlock(id: 'tail', text: '  End.\n\t'),
          ],
        ),
        const TextSection(id: 's1', blocks: []),
        const TextSection(
          id: 's2',
          blocks: [
            TextBlock(id: 'other', text: 'Mara arrives.\nNorthwatch patrol.'),
          ],
        ),
      ]);
      final source = AnalysisSource(documents: store);
      final manifest = await source.buildManifest('source');
      expect(store.loaded, ['s0', 's1', 's2']);
      expect(manifest.sectionCount, 3);
      expect(manifest.blockCount, 4);
      expect(manifest.sections[1].blockCount, 0);
      expect(jsonEncode(manifest.toJson()), isNot(contains('Mara arrives')));
      expect(manifest.toAdmissionJson(), isNot(contains('chunks')));
      final reconstructed = <String, String>{};
      final offsets = <String, int>{};
      for (final descriptor in manifest.chunks) {
        final input = await source.loadChunk('source', descriptor);
        expect(input.textLength, lessThanOrEqualTo(analysisInputMaxUnits));
        expect(
          input.overlap.fold<int>(0, (sum, span) => sum + span.text.length),
          lessThanOrEqualTo(analysisOverlapMaxUnits),
        );
        for (final span in input.primary) {
          final key = '${span.sectionId}/${span.blockId}';
          expect(span.startOffset, offsets[key] ?? 0);
          offsets[key] = span.endOffset;
          reconstructed.update(
            key,
            (text) => text + span.text,
            ifAbsent: () => span.text,
          );
          final text = store
              .sections[span.sectionOrdinal]
              .blocks[span.blockOrdinal]
              .text;
          expect(GraphemeBoundaries(text).contains(span.startOffset), isTrue);
          expect(GraphemeBoundaries(text).contains(span.endOffset), isTrue);
        }
      }
      expect(reconstructed, {
        's0/empty': '',
        's0/long': large,
        's0/tail': '  End.\n\t',
        's2/other': 'Mara arrives.\nNorthwatch patrol.',
      });
      final again = await source.buildManifest('source');
      expect(again.toJson(), manifest.toJson());
      expect(
        AnalysisSourceManifest.fromJson(manifest.toJson()).toJson(),
        manifest.toJson(),
      );
    },
  );

  test(
    'overlap is exactly preceding context and never primary coverage',
    () async {
      final store = _SourceStore([
        TextSection(
          id: 's0',
          blocks: [TextBlock(id: 'a', text: 'x' * 6000)],
        ),
        const TextSection(
          id: 's1',
          blocks: [TextBlock(id: 'b', text: 'next')],
        ),
      ]);
      final source = AnalysisSource(documents: store);
      final manifest = await source.buildManifest('source');
      final input = await source.loadChunk('source', manifest.chunks[1]);
      expect(input.primary.single.blockId, 'b');
      expect(input.overlap.single.blockId, 'a');
      expect(input.overlap.single.startOffset, 5000);
      expect(input.overlap.single.endOffset, 6000);
      expect(input.overlap.single.text, 'x' * 1000);
    },
  );

  test('reload rejects changed source and invalid grapheme offsets without snapping', () async {
    final store = _SourceStore([
      const TextSection(
        id: 's0',
        blocks: [TextBlock(id: 'a', text: 'e\u0301😀')],
      ),
    ]);
    final source = AnalysisSource(documents: store);
    final manifest = await source.buildManifest('source');
    final original = manifest.chunks.single;
    final span = original.primary.single;
    final invalid = AnalysisSpanDescriptor(
      sectionOrdinal: span.sectionOrdinal,
      sectionId: span.sectionId,
      blockOrdinal: span.blockOrdinal,
      blockId: span.blockId,
      startOffset: 1,
      endOffset: span.endOffset,
      blockLength: span.blockLength,
      hash: analysisSpanHash(
        sectionOrdinal: 0,
        sectionId: 's0',
        blockOrdinal: 0,
        blockId: 'a',
        startOffset: 1,
        endOffset: 4,
        text: '\u0301😀',
      ),
    );
    final invalidChunk = AnalysisChunkDescriptor(
      ordinal: 0,
      hash: analysisPrimitiveHash([invalid.hash]),
      primary: [invalid],
      overlap: const [],
      overlapHash: analysisPrimitiveHash([]),
    );
    await expectLater(
      source.loadChunk('source', invalidChunk),
      throwsFormatException,
    );
    store.sections[0] = const TextSection(
      id: 's0',
      blocks: [TextBlock(id: 'a', text: 'o\u0301😀')],
    );
    await expectLater(
      source.loadChunk('source', original),
      throwsFormatException,
    );
    expect(
      () => AnalysisSpan(
        start: const TextPosition(sectionId: 's0', blockId: 'a'),
        end: const TextPosition(sectionId: 's0', blockId: 'a'),
      ),
      throwsFormatException,
    );
  });

  test(
    'tiny and empty blocks make bounded descriptor windows without omissions',
    () async {
      final store = _SourceStore([
        TextSection(
          id: 's0',
          blocks: List.generate(
            1800,
            (index) => TextBlock(id: 'p$index', text: index.isEven ? '' : 'x'),
          ),
        ),
      ]);
      final manifest = await AnalysisSource(documents: store)
          .buildManifest('source');
      expect(manifest.chunks.length, greaterThan(1));
      expect(manifest.chunks.expand((chunk) => chunk.primary).length, 1800);
      final pages = analysisDescriptorPages(manifest.chunks);
      expect(pages.length, manifest.pageCount);
      for (final page in pages) {
        expect(page.chunks.length, lessThanOrEqualTo(100));
        expect(
          utf8.encode(jsonEncode(page.toJson())).length,
          lessThanOrEqualTo(analysisPageMaxBytes),
        );
      }
    },
  );

  test(
    'descriptor pages split at 100 without truncation and reject oversize',
    () {
      final chunks = List.generate(
        101,
        (index) => AnalysisChunkDescriptor(
          ordinal: index,
          hash: 'h',
          primary: const [],
          overlap: const [],
          overlapHash: 'o',
        ),
      );
      final pages = analysisDescriptorPages(chunks);
      expect(pages.map((page) => page.chunks.length), [100, 1]);
      expect(
        () => AnalysisDescriptorPage(chunks: chunks),
        throwsFormatException,
      );
      final huge = AnalysisChunkDescriptor(
        ordinal: 0,
        hash: 'x' * analysisPageMaxBytes,
        primary: const [],
        overlap: const [],
        overlapHash: 'o',
      );
      expect(() => analysisDescriptorPages([huge]), throwsFormatException);
    },
  );

  test('empty sections create no invented extraction or evidence', () async {
    final source = AnalysisSource(
      documents: _SourceStore([const TextSection(id: 's0', blocks: [])]),
    );
    final manifest = await source.buildManifest('source');
    expect(manifest.sections.single.blockCount, 0);
    expect(manifest.chunks, isEmpty);
    expect(manifest.pageCount, 0);
    expect(manifest.documentDigest, analysisPrimitiveHash([]));
  });

  test(
    'a grapheme larger than hard input bound is rejected not bisected',
    () async {
      final source = AnalysisSource(
        documents: _SourceStore([
          TextSection(
            id: 's0',
            blocks: [TextBlock(id: 'a', text: 'e${'\u0301' * 8000}')],
          ),
        ]),
      );
      await expectLater(source.buildManifest('source'), throwsFormatException);
    },
  );
}

/// Direct constructors deliberately allow empty apparatus not accepted by import.
class _SourceStore extends TextDocumentStore {
  _SourceStore(this.sections);
  final List<TextSection> sections;
  final loaded = <String>[];

  @override
  Future<TextDocument> load(String sourcePath) async => TextDocument(
    title: 'Source fixture',
    authors: const [],
    contents: const [],
    sections: sections
        .map(
          (section) => SectionSummary(
            id: section.id,
            title: section.id,
            source: section.id,
            length: section.length,
          ),
        )
        .toList(),
  );

  @override
  Future<TextSection> loadSection(String sourcePath, String id) async {
    loaded.add(id);
    return sections.firstWhere((section) => section.id == id);
  }
}
