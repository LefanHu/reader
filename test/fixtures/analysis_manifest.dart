import 'package:reader/book_analysis/analysis_source.dart';
import 'package:reader/book_analysis/analysis_source_models.dart';

/// One-block chunk whose text holds combining marks, an astral emoji and
/// surrounding whitespace, so hashes cover exact UTF-16 offsets.
AnalysisChunkInput analysisFixtureChunk({String text = '  e\u0301😀\n\t'}) {
  final hash = analysisSpanHash(
    sectionOrdinal: 0,
    sectionId: 's0',
    blockOrdinal: 0,
    blockId: 'p0',
    startOffset: 0,
    endOffset: text.length,
    text: text,
  );
  return AnalysisChunkInput(
    ordinal: 0,
    hash: analysisPrimitiveHash([hash]),
    primary: [
      AnalysisSourceSpan(
        sectionOrdinal: 0,
        sectionId: 's0',
        blockOrdinal: 0,
        blockId: 'p0',
        startOffset: 0,
        endOffset: text.length,
        blockLength: text.length,
        hash: hash,
        text: text,
      ),
    ],
    overlap: const [],
    overlapHash: analysisPrimitiveHash([]),
  );
}

/// Valid single-section, single-chunk manifest at the client's pinned
/// schema, analysis, prompt and model versions.
AnalysisSourceManifest analysisFixtureManifest() {
  final chunk = analysisFixtureChunk();
  return AnalysisSourceManifest(
    documentDigest: analysisPrimitiveHash([
      [0, chunk.hash],
    ]),
    sectionCount: 1,
    blockCount: 1,
    chunkCount: 1,
    pageCount: 1,
    sections: const [
      AnalysisSectionDescriptor(ordinal: 0, id: 's0', blockCount: 1),
    ],
    chunks: [
      AnalysisChunkDescriptor(
        ordinal: 0,
        hash: chunk.hash,
        primary: chunk.primary.map((span) => span.descriptor).toList(),
        overlap: const [],
        overlapHash: chunk.overlapHash,
      ),
    ],
  );
}
