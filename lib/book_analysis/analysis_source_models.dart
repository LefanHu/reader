import 'dart:convert';

import 'analysis_limits.dart';
import 'analysis_model.dart';

/// Prose-free identity and exact offsets of one normalized source slice.
class AnalysisSpanDescriptor {
  /// Empty blocks are represented by start=end=0, never used as evidence.
  const AnalysisSpanDescriptor({
    required this.sectionOrdinal,
    required this.sectionId,
    required this.blockOrdinal,
    required this.blockId,
    required this.startOffset,
    required this.endOffset,
    required this.blockLength,
    required this.hash,
  });

  /// Zero-based section position in the normalized document.
  final int sectionOrdinal;

  /// Stable normalized section identity.
  final String sectionId;

  /// Zero-based block position within its section.
  final int blockOrdinal;

  /// Stable normalized block identity.
  final String blockId;

  /// Included block-local UTF-16 offset on a grapheme boundary.
  final int startOffset;

  /// Excluded block-local UTF-16 offset on a grapheme boundary.
  final int endOffset;

  /// Full original block length, proving contiguous primary coverage.
  final int blockLength;

  /// SHA-256 of the shared compact primitive-array source identity.
  final String hash;

  /// Prose-free manifest representation.
  Map<String, dynamic> toJson() => {
    'sectionOrdinal': sectionOrdinal,
    'sectionId': sectionId,
    'blockOrdinal': blockOrdinal,
    'blockId': blockId,
    'startOffset': startOffset,
    'endOffset': endOffset,
    'blockLength': blockLength,
    'hash': hash,
  };

  /// Restores an exact descriptor; the source mapper validates actual text.
  factory AnalysisSpanDescriptor.fromJson(Map<String, dynamic> json) =>
      AnalysisSpanDescriptor(
        sectionOrdinal: json['sectionOrdinal'] as int,
        sectionId: json['sectionId'] as String,
        blockOrdinal: json['blockOrdinal'] as int,
        blockId: json['blockId'] as String,
        startOffset: json['startOffset'] as int,
        endOffset: json['endOffset'] as int,
        blockLength: json['blockLength'] as int,
        hash: json['hash'] as String,
      );
}

/// Ephemeral upload slice; raw text is never part of the durable manifest.
class AnalysisSourceSpan extends AnalysisSpanDescriptor {
  /// Attaches untouched normalized text to its verified descriptor.
  const AnalysisSourceSpan({
    required super.sectionOrdinal,
    required super.sectionId,
    required super.blockOrdinal,
    required super.blockId,
    required super.startOffset,
    required super.endOffset,
    required super.blockLength,
    required super.hash,
    required this.text,
  });

  /// Exact original substring, including whitespace and combining sequences.
  final String text;

  /// Drops prose before retaining coverage metadata.
  AnalysisSpanDescriptor get descriptor => AnalysisSpanDescriptor(
    sectionOrdinal: sectionOrdinal,
    sectionId: sectionId,
    blockOrdinal: blockOrdinal,
    blockId: blockId,
    startOffset: startOffset,
    endOffset: endOffset,
    blockLength: blockLength,
    hash: hash,
  );

  /// Upload representation, never used for a persisted source manifest.
  @override
  Map<String, dynamic> toJson() => {...super.toJson(), 'text': text};

  /// Restores transient transport text; not a persisted source-manifest decoder.
  factory AnalysisSourceSpan.fromJson(Map<String, dynamic> json) =>
      AnalysisSourceSpan(
        sectionOrdinal: json['sectionOrdinal'] as int,
        sectionId: json['sectionId'] as String,
        blockOrdinal: json['blockOrdinal'] as int,
        blockId: json['blockId'] as String,
        startOffset: json['startOffset'] as int,
        endOffset: json['endOffset'] as int,
        blockLength: json['blockLength'] as int,
        hash: json['hash'] as String,
        text: json['text'] as String,
      );
}

/// Immutable ordered window coverage with separately hashed preceding context.
class AnalysisChunkDescriptor {
  /// Primary slices cover the document once; overlap is context only.
  const AnalysisChunkDescriptor({
    required this.ordinal,
    required this.hash,
    required this.primary,
    required this.overlap,
    required this.overlapHash,
  });

  /// Zero-based extraction order.
  final int ordinal;

  /// SHA-256 of the compact ordered array of primary span hashes.
  final String hash;

  /// Exact-once primary coverage, including empty-block descriptors.
  final List<AnalysisSpanDescriptor> primary;

  /// Preceding context that must not emit duplicate primary records.
  final List<AnalysisSpanDescriptor> overlap;

  /// SHA-256 of the compact ordered array of overlap span hashes.
  final String overlapHash;

  /// Durable window descriptor containing no source text.
  Map<String, dynamic> toJson() => {
    'ordinal': ordinal,
    'hash': hash,
    'primary': primary.map((span) => span.toJson()).toList(),
    'overlap': overlap.map((span) => span.toJson()).toList(),
    'overlapHash': overlapHash,
  };

  /// Restores ordered coverage metadata without loading chapter prose.
  factory AnalysisChunkDescriptor.fromJson(Map<String, dynamic> json) =>
      AnalysisChunkDescriptor(
        ordinal: json['ordinal'] as int,
        hash: json['hash'] as String,
        primary: List.unmodifiable(
          (json['primary'] as List).map(
            (item) => AnalysisSpanDescriptor.fromJson(
              (item as Map).cast<String, dynamic>(),
            ),
          ),
        ),
        overlap: List.unmodifiable(
          (json['overlap'] as List).map(
            (item) => AnalysisSpanDescriptor.fromJson(
              (item as Map).cast<String, dynamic>(),
            ),
          ),
        ),
        overlapHash: json['overlapHash'] as String,
      );
}

/// Bounded, ephemeral normalized source request for one extraction operation.
class AnalysisChunkInput {
  /// Captures verified primary text and non-primary preceding context.
  const AnalysisChunkInput({
    required this.ordinal,
    required this.hash,
    required this.primary,
    required this.overlap,
    required this.overlapHash,
  });

  /// Zero-based extraction order, identical to its admitted descriptor.
  final int ordinal;

  /// Admitted primary hash; retries retain identical content identity.
  final String hash;

  /// Exact normalized primary slices.
  final List<AnalysisSourceSpan> primary;

  /// Exact normalized context slices, never primary coverage.
  final List<AnalysisSourceSpan> overlap;

  /// Separately admitted overlap hash.
  final String overlapHash;

  /// Maximum 8,000 UTF-16 code units including context.
  int get textLength =>
      primary.fold<int>(0, (total, span) => total + span.text.length) +
      overlap.fold<int>(0, (total, span) => total + span.text.length);

  /// Upload body retains source whitespace verbatim.
  Map<String, dynamic> toJson() => {
    'ordinal': ordinal,
    'hash': hash,
    'primary': primary.map((span) => span.toJson()).toList(),
    'overlap': overlap.map((span) => span.toJson()).toList(),
    'overlapHash': overlapHash,
  };

  /// Restores a bounded transient request without normalizing its text again.
  factory AnalysisChunkInput.fromJson(Map<String, dynamic> json) {
    final input = AnalysisChunkInput(
      ordinal: json['ordinal'] as int,
      hash: json['hash'] as String,
      primary: List.unmodifiable(
        (json['primary'] as List).map(
          (item) => AnalysisSourceSpan.fromJson(
            (item as Map).cast<String, dynamic>(),
          ),
        ),
      ),
      overlap: List.unmodifiable(
        (json['overlap'] as List).map(
          (item) => AnalysisSourceSpan.fromJson(
            (item as Map).cast<String, dynamic>(),
          ),
        ),
      ),
      overlapHash: json['overlapHash'] as String,
    );
    if (input.textLength > analysisInputMaxUnits ||
        input.overlap.fold<int>(0, (total, span) => total + span.text.length) >
            analysisOverlapMaxUnits) {
      throw const FormatException('Oversized analysis chunk input.');
    }
    return input;
  }
}

/// Section cardinality proving that omitted blocks cannot look like coverage.
class AnalysisSectionDescriptor {
  /// Sections with no blocks still retain their ordered identity.
  const AnalysisSectionDescriptor({
    required this.ordinal,
    required this.id,
    required this.blockCount,
  });

  /// Zero-based normalized section order.
  final int ordinal;

  /// Stable normalized section identity.
  final String id;

  /// Number of blocks, including empty normalized blocks.
  final int blockCount;

  /// Compact cardinality metadata.
  Map<String, dynamic> toJson() => {
    'ordinal': ordinal,
    'id': id,
    'blockCount': blockCount,
  };

  /// Restores section coverage metadata.
  factory AnalysisSectionDescriptor.fromJson(Map<String, dynamic> json) =>
      AnalysisSectionDescriptor(
        ordinal: json['ordinal'] as int,
        id: json['id'] as String,
        blockCount: json['blockCount'] as int,
      );
}

/// An ordered upload page bounded by both descriptor count and UTF-8 bytes.
class AnalysisDescriptorPage {
  /// Rejects oversize pages rather than truncating coverage.
  AnalysisDescriptorPage({required List<AnalysisChunkDescriptor> chunks})
    : chunks = List.unmodifiable(chunks) {
    if (chunks.isEmpty ||
        chunks.length > analysisDescriptorPageMaxChunks ||
        utf8.encode(jsonEncode(toJson())).length > analysisPageMaxBytes) {
      throw const FormatException('Invalid analysis descriptor page size.');
    }
  }

  /// At most 100 immutable, ordered chunk descriptors.
  final List<AnalysisChunkDescriptor> chunks;

  /// Exact descriptor-page PUT payload.
  Map<String, dynamic> toJson() => {
    'chunks': chunks.map((chunk) => chunk.toJson()).toList(),
  };

  /// Restores a bounded descriptor page without raw source text.
  factory AnalysisDescriptorPage.fromJson(Map<String, dynamic> json) =>
      AnalysisDescriptorPage(
        chunks: (json['chunks'] as List)
            .map(
              (item) => AnalysisChunkDescriptor.fromJson(
                (item as Map).cast<String, dynamic>(),
              ),
            )
            .toList(),
      );
}

/// Deterministic generation source identity, containing coverage but no prose.
class AnalysisSourceManifest {
  /// Model identity is immutable across retries.
  const AnalysisSourceManifest({
    this.model = analysisModel,
    required this.documentDigest,
    required this.sectionCount,
    required this.blockCount,
    required this.chunkCount,
    required this.pageCount,
    required this.sections,
    required this.chunks,
  });

  /// Immutable extraction model snapshot.
  final String model;

  /// SHA-256 of ordered compact [ordinal, primaryHash] pairs.
  final String documentDigest;

  /// All normalized sections, including zero-block sections.
  final int sectionCount;

  /// All normalized blocks, including zero-length blocks.
  final int blockCount;

  /// Required primary extraction windows.
  final int chunkCount;

  /// Required bounded descriptor upload pages.
  final int pageCount;

  /// Ordered section cardinalities.
  final List<AnalysisSectionDescriptor> sections;

  /// Ordered coverage descriptors, never raw chapter prose.
  final List<AnalysisChunkDescriptor> chunks;

  /// Admission omits chunks, which are uploaded as bounded manifest pages.
  Map<String, dynamic> toAdmissionJson() => {
    'model': model,
    'documentDigest': documentDigest,
    'sectionCount': sectionCount,
    'blockCount': blockCount,
    'chunkCount': chunkCount,
    'pageCount': pageCount,
    'sections': sections.map((section) => section.toJson()).toList(),
  };

  /// Prose-free durable manifest representation.
  Map<String, dynamic> toJson() => {
    ...toAdmissionJson(),
    'chunks': chunks.map((chunk) => chunk.toJson()).toList(),
  };

  /// Restores metadata for the configured extraction model.
  factory AnalysisSourceManifest.fromJson(Map<String, dynamic> json) {
    if (json['model'] != analysisModel) {
      throw const FormatException('Unsupported book analysis manifest.');
    }
    return AnalysisSourceManifest(
      documentDigest: json['documentDigest'] as String,
      sectionCount: json['sectionCount'] as int,
      blockCount: json['blockCount'] as int,
      chunkCount: json['chunkCount'] as int,
      pageCount: json['pageCount'] as int,
      sections: List.unmodifiable(
        (json['sections'] as List).map(
          (item) => AnalysisSectionDescriptor.fromJson(
            (item as Map).cast<String, dynamic>(),
          ),
        ),
      ),
      chunks: List.unmodifiable(
        (json['chunks'] as List).map(
          (item) => AnalysisChunkDescriptor.fromJson(
            (item as Map).cast<String, dynamic>(),
          ),
        ),
      ),
    );
  }
}
