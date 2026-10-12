import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../text/document_store.dart';
import '../text/grapheme_boundary.dart';
import '../text/text_section.dart';
import 'analysis_source_models.dart';
import 'analysis_limits.dart';

/// SHA-256 of compact primitive JSON; identical to Node JSON.stringify arrays.
String analysisPrimitiveHash(List<Object?> value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

/// Hashes untouched normalized text and its original block-local coordinates.
String analysisSpanHash({
  required int sectionOrdinal,
  required String sectionId,
  required int blockOrdinal,
  required String blockId,
  required int startOffset,
  required int endOffset,
  required String text,
}) => analysisPrimitiveHash([
  sectionOrdinal,
  sectionId,
  blockOrdinal,
  blockId,
  startOffset,
  endOffset,
  text,
]);

/// Partitions prose-free descriptors without changing their extraction order.
List<AnalysisDescriptorPage> analysisDescriptorPages(
  List<AnalysisChunkDescriptor> chunks,
) {
  final pages = <AnalysisDescriptorPage>[];
  var pending = <AnalysisChunkDescriptor>[];
  var bytes = utf8.encode('{"chunks":[]}').length;
  for (final chunk in chunks) {
    final size = utf8.encode(jsonEncode(chunk.toJson())).length;
    if (size + utf8.encode('{"chunks":[]}').length > analysisPageMaxBytes) {
      throw const FormatException(
        'Analysis chunk descriptor exceeds page limit.',
      );
    }
    final addition = size + (pending.isEmpty ? 0 : 1);
    if (pending.length == analysisDescriptorPageMaxChunks ||
        bytes + addition > analysisPageMaxBytes) {
      pages.add(AnalysisDescriptorPage(chunks: pending));
      pending = [];
      bytes = utf8.encode('{"chunks":[]}').length;
    }
    bytes += size + (pending.isEmpty ? 0 : 1);
    pending.add(chunk);
  }
  if (pending.isNotEmpty) pages.add(AnalysisDescriptorPage(chunks: pending));
  return List.unmodifiable(pages);
}

/// Maps shared normalized storage without another eager book-text index.
///
/// Only one section and a bounded primary/context window retain prose at once.
/// The returned manifest is safe to persist; loadChunk reconstructs raw uploads
/// on demand and rejects changed text/offsets rather than snapping evidence.
class AnalysisSource {
  /// Uses the same disk boundary as rendering; injectable for deterministic IO.
  AnalysisSource({TextDocumentStore? documents})
    : documents = documents ?? TextDocumentStore();

  /// Immutable normalized source boundary, never an illustration text cache.
  final TextDocumentStore documents;

  /// Covers every block exactly once, preserving empty blocks and sections.
  Future<AnalysisSourceManifest> buildManifest(String sourcePath) async {
    final document = await documents.load(sourcePath);
    final sections = <AnalysisSectionDescriptor>[];
    final chunks = <AnalysisChunkDescriptor>[];
    var primary = <AnalysisSourceSpan>[];
    var preceding = <AnalysisSourceSpan>[];
    var units = 0;
    // Reserve fixed chunk/page framing so even many tiny/empty blocks fit.
    var descriptorBytes = 0;
    var blockCount = 0;
    final sectionIds = <String>{};

    void flush() {
      if (primary.isEmpty) return;
      var overlap = _tail(
        preceding,
        (analysisInputMaxUnits - units).clamp(0, analysisOverlapMaxUnits),
      );
      var remainingBytes = analysisPageMaxBytes - 512 - descriptorBytes;
      final boundedOverlap = <AnalysisSourceSpan>[];
      for (final span in overlap.reversed) {
        final bytes =
            utf8.encode(jsonEncode(span.descriptor.toJson())).length + 1;
        if (bytes > remainingBytes) break;
        boundedOverlap.add(span);
        remainingBytes -= bytes;
      }
      overlap = boundedOverlap.reversed.toList();
      chunks.add(
        AnalysisChunkDescriptor(
          ordinal: chunks.length,
          hash: analysisPrimitiveHash(
            primary.map((span) => span.hash).toList(),
          ),
          primary: List.unmodifiable(primary.map((span) => span.descriptor)),
          overlap: List.unmodifiable(overlap.map((span) => span.descriptor)),
          overlapHash: analysisPrimitiveHash(
            overlap.map((span) => span.hash).toList(),
          ),
        ),
      );
      preceding = _tail([...preceding, ...primary], analysisOverlapMaxUnits);
      primary = [];
      units = 0;
      descriptorBytes = 0;
    }

    void add(AnalysisSourceSpan span) {
      final bytes =
          utf8.encode(jsonEncode(span.descriptor.toJson())).length + 1;
      if (bytes > analysisPageMaxBytes - 512) {
        throw const FormatException(
          'Analysis span descriptor exceeds page limit.',
        );
      }
      if (descriptorBytes + bytes > analysisPageMaxBytes - 512) flush();
      primary.add(span);
      descriptorBytes += bytes;
      units += span.text.length;
    }

    for (
      var sectionOrdinal = 0;
      sectionOrdinal < document.sections.length;
      sectionOrdinal++
    ) {
      final summary = document.sections[sectionOrdinal];
      if (!sectionIds.add(summary.id)) {
        throw const FormatException('Duplicate analysis section identity.');
      }
      final section = await documents.loadSection(sourcePath, summary.id);
      if (section.id != summary.id) {
        throw const FormatException('Analysis section identity mismatch.');
      }
      sections.add(
        AnalysisSectionDescriptor(
          ordinal: sectionOrdinal,
          id: section.id,
          blockCount: section.blocks.length,
        ),
      );
      blockCount += section.blocks.length;
      final blockIds = <String>{};
      for (
        var blockOrdinal = 0;
        blockOrdinal < section.blocks.length;
        blockOrdinal++
      ) {
        final block = section.blocks[blockOrdinal];
        if (block.id.isEmpty || !blockIds.add(block.id)) {
          throw const FormatException('Invalid analysis block identity.');
        }
        final boundaries = block.text.length > analysisPrimaryTarget
            ? GraphemeBoundaries(block.text)
            : null;
        // Ordinary blocks stay whole; only oversized blocks need local slices.
        if (block.text.length <= analysisPrimaryTarget) {
          if (units + block.text.length > analysisPrimaryTarget) flush();
          add(
            _span(
              sectionOrdinal,
              section.id,
              blockOrdinal,
              block.id,
              block.text.length,
              0,
              block.text.length,
              block.text,
            ),
          );
          if (units >= analysisPrimaryTarget) flush();
          continue;
        }
        flush();
        var start = 0;
        while (start < block.text.length) {
          var end = boundaries!.floor(start + analysisPrimaryTarget);
          if (end == start) end = boundaries.ceil(start + 1);
          if (end - start > analysisInputMaxUnits) {
            throw const FormatException(
              'Analysis grapheme exceeds input limit.',
            );
          }
          add(
            _span(
              sectionOrdinal,
              section.id,
              blockOrdinal,
              block.id,
              block.text.length,
              start,
              end,
              block.text.substring(start, end),
            ),
          );
          start = end;
          // A boundary below the target still owns a complete oversized slice.
          flush();
        }
      }
    }
    flush();
    final pages = analysisDescriptorPages(chunks);
    return AnalysisSourceManifest(
      documentDigest: analysisPrimitiveHash(
        chunks.map((chunk) => <Object?>[chunk.ordinal, chunk.hash]).toList(),
      ),
      sectionCount: sections.length,
      blockCount: blockCount,
      chunkCount: chunks.length,
      pageCount: pages.length,
      sections: List.unmodifiable(sections),
      chunks: List.unmodifiable(chunks),
    );
  }

  /// Reloads one admitted window, checking identities, Unicode bounds and hashes.
  /// No raw text is cached or persisted after the caller releases the request.
  Future<AnalysisChunkInput> loadChunk(
    String sourcePath,
    AnalysisChunkDescriptor descriptor,
  ) async {
    final document = await documents.load(sourcePath);
    TextSection? current;
    var currentOrdinal = -1;
    final primary = <AnalysisSourceSpan>[];
    final overlap = <AnalysisSourceSpan>[];
    var totalUnits = 0;
    var overlapUnits = 0;
    for (final group in [descriptor.overlap, descriptor.primary]) {
      final target = identical(group, descriptor.overlap) ? overlap : primary;
      for (final span in group) {
        if (span.sectionOrdinal < 0 ||
            span.sectionOrdinal >= document.sections.length ||
            document.sections[span.sectionOrdinal].id != span.sectionId) {
          throw const FormatException('Analysis source section changed.');
        }
        if (currentOrdinal != span.sectionOrdinal) {
          current = null;
          current = await documents.loadSection(sourcePath, span.sectionId);
          currentOrdinal = span.sectionOrdinal;
        }
        final section = current!;
        if (section.id != span.sectionId ||
            span.blockOrdinal < 0 ||
            span.blockOrdinal >= section.blocks.length) {
          throw const FormatException('Analysis source block changed.');
        }
        final block = section.blocks[span.blockOrdinal];
        if (block.id != span.blockId ||
            block.text.length != span.blockLength ||
            span.startOffset < 0 ||
            span.endOffset < span.startOffset ||
            span.endOffset > block.text.length ||
            (span.startOffset == span.endOffset &&
                (block.text.isNotEmpty || target == overlap))) {
          throw const FormatException('Invalid analysis source offsets.');
        }
        final boundaries = GraphemeBoundaries(block.text);
        if (!boundaries.contains(span.startOffset) ||
            !boundaries.contains(span.endOffset)) {
          throw const FormatException('Analysis source splits a grapheme.');
        }
        final loaded = _span(
          span.sectionOrdinal,
          span.sectionId,
          span.blockOrdinal,
          span.blockId,
          span.blockLength,
          span.startOffset,
          span.endOffset,
          block.text.substring(span.startOffset, span.endOffset),
        );
        if (loaded.hash != span.hash) {
          throw const FormatException('Analysis source hash changed.');
        }
        totalUnits += loaded.text.length;
        if (target == overlap) overlapUnits += loaded.text.length;
        if (totalUnits > analysisInputMaxUnits ||
            overlapUnits > analysisOverlapMaxUnits) {
          throw const FormatException('Analysis source exceeds input limit.');
        }
        target.add(loaded);
      }
    }
    if (descriptor.ordinal < 0 ||
        primary.isEmpty ||
        descriptor.hash !=
            analysisPrimitiveHash(primary.map((span) => span.hash).toList()) ||
        descriptor.overlapHash !=
            analysisPrimitiveHash(overlap.map((span) => span.hash).toList())) {
      throw const FormatException('Analysis chunk hash changed.');
    }
    return AnalysisChunkInput(
      ordinal: descriptor.ordinal,
      hash: descriptor.hash,
      primary: List.unmodifiable(primary),
      overlap: List.unmodifiable(overlap),
      overlapHash: descriptor.overlapHash,
    );
  }
}

AnalysisSourceSpan _span(
  int sectionOrdinal,
  String sectionId,
  int blockOrdinal,
  String blockId,
  int blockLength,
  int start,
  int end,
  String text,
) => AnalysisSourceSpan(
  sectionOrdinal: sectionOrdinal,
  sectionId: sectionId,
  blockOrdinal: blockOrdinal,
  blockId: blockId,
  blockLength: blockLength,
  startOffset: start,
  endOffset: end,
  text: text,
  hash: analysisSpanHash(
    sectionOrdinal: sectionOrdinal,
    sectionId: sectionId,
    blockOrdinal: blockOrdinal,
    blockId: blockId,
    startOffset: start,
    endOffset: end,
    text: text,
  ),
);

List<AnalysisSourceSpan> _tail(List<AnalysisSourceSpan> spans, int budget) {
  final reversed = <AnalysisSourceSpan>[];
  for (final span in spans.reversed) {
    if (budget <= 0) break;
    if (span.text.isEmpty) continue;
    if (span.text.length <= budget) {
      reversed.add(span);
      budget -= span.text.length;
      continue;
    }
    final start = GraphemeBoundaries(span.text).ceil(span.text.length - budget);
    if (start < span.text.length) {
      reversed.add(
        _span(
          span.sectionOrdinal,
          span.sectionId,
          span.blockOrdinal,
          span.blockId,
          span.blockLength,
          span.startOffset + start,
          span.endOffset,
          span.text.substring(start),
        ),
      );
    }
    // Do not skip a too-large trailing grapheme and invent noncontiguous context.
    break;
  }
  return reversed.reversed.toList();
}
