import 'grapheme_boundary.dart';
import 'narration_chunk.dart';
import 'narration_playback_unit.dart';
import 'narration_range.dart';
import 'text_position.dart';
import 'text_section.dart';

/// Local-only batching policy.
const appleSentenceNarrationPolicy = 'apple-sentence';

final _clauseDelimiter = RegExp(r'[,;:，；：、—–]');

/// Clips exact normalized text using native NLTokenizer UTF-16 sentence pairs.
/// Pairs are keyed by stable block ID, ordered, nonoverlapping and in bounds.
/// Missing pairs mean one sentence. Interior grapheme boundaries expand/merge.
/// Whitespace belongs to adjacent speech, never to an independent silent clip.
List<NarrationPlaybackUnit> sentenceNarrationUnits(
  TextSection section, {
  required Map<String, List<({int start, int end})>> sentenceRanges,
  TextPosition? from,
}) {
  final anchor = from == null ? section.start : section.resolve(from);
  final result = <NarrationPlaybackUnit>[];
  var started = false;
  for (final block in section.blocks) {
    if (block.id == anchor.blockId) started = true;
    if (!started) continue;
    final resume = block.id == anchor.blockId ? anchor.offset : 0;
    if (resume >= block.text.length) continue;
    final boundaries = GraphemeBoundaries(block.text);
    final offsets = boundaries.offsets;
    for (var i = 0; i + 1 < offsets.length; i++) {
      if (offsets[i + 1] - offsets[i] > maxNarrationClipUnits &&
          offsets[i] >= resume) {
        throw const FormatException(
          'Narration grapheme exceeds 3,000 UTF-16 units.',
        );
      }
    }
    int floor(int value) => boundaries.floor(value);
    int ceil(int value) => boundaries.ceil(value);
    final sentences = <({int start, int end})>[];
    var previousEnd = 0;
    for (final pair in sentenceRanges[block.id] ?? const []) {
      if (pair.start < previousEnd ||
          pair.start < 0 ||
          pair.end <= pair.start ||
          pair.end > block.text.length) {
        throw const FormatException('Invalid native sentence boundaries.');
      }
      previousEnd = pair.end;
      final expanded = (start: floor(pair.start), end: ceil(pair.end));
      if (sentences.isNotEmpty && expanded.start < sentences.last.end) {
        final previous = sentences.removeLast();
        sentences.add((start: previous.start, end: expanded.end));
      } else {
        sentences.add(expanded);
      }
    }
    // Tokenizers may return whitespace ranges. Absorb them into adjacent speech
    // so trailing whitespace is retained without a silent final playback unit.
    sentences.removeWhere(
      (pair) => block.text.substring(pair.start, pair.end).trim().isEmpty,
    );
    if (sentences.isEmpty) sentences.add((start: 0, end: block.text.length));
    TextPosition position(int offset) =>
        TextPosition(sectionId: section.id, blockId: block.id, offset: offset);
    var coverageStart = 0;
    var pendingStart = resume;
    for (var i = 0; i < sentences.length; i++) {
      final sentence = sentences[i];
      final coverageEnd = i + 1 < sentences.length
          ? sentences[i + 1].start
          : block.text.length;
      final start = coverageStart < resume ? resume : coverageStart;
      coverageStart = coverageEnd;
      if (start >= coverageEnd) continue;
      // Carry whitespace-only gaps into the following spoken sentence.
      if (block.text.substring(start, coverageEnd).trim().isEmpty) continue;
      var decorativeStart = sentence.start;
      var decorativeEnd = sentence.end;
      while (decorativeStart < decorativeEnd) {
        final next = ceil(decorativeStart + 1);
        if (block.text.substring(decorativeStart, next).trim().isNotEmpty) {
          break;
        }
        decorativeStart = next;
      }
      while (decorativeEnd > decorativeStart) {
        final previous = floor(decorativeEnd - 1);
        if (block.text.substring(previous, decorativeEnd).trim().isNotEmpty) {
          break;
        }
        decorativeEnd = previous;
      }
      // Native ranges excluding prose are unusable decorative metadata.
      if (decorativeStart == decorativeEnd) {
        decorativeStart = start;
        decorativeEnd = coverageEnd;
      }
      final fallback = NarrationRange(
        position(decorativeStart),
        position(decorativeEnd),
      );
      var offset = pendingStart > start ? pendingStart : start;
      // pendingStart retains leading whitespace skipped by a previous sentence.
      if (pendingStart < start) offset = pendingStart;
      var spokenEnd = coverageEnd;
      while (spokenEnd > offset) {
        final previous = floor(spokenEnd - 1);
        if (block.text.substring(previous, spokenEnd).trim().isNotEmpty) break;
        spokenEnd = previous;
      }
      while (offset < coverageEnd) {
        var end = floor((offset + 300).clamp(0, coverageEnd));
        if (end == offset) end = ceil(offset + 1);
        if (end < coverageEnd) {
          final half = offset + 150;
          var clause = 0;
          var space = 0;
          var index = boundaries.floorIndex(offset);
          while (index + 1 < offsets.length && offsets[index + 1] <= end) {
            final a = offsets[index];
            final b = offsets[index + 1];
            final cluster = block.text.substring(a, b);
            if (b >= half) {
              if (_clauseDelimiter.hasMatch(cluster)) clause = b;
              if (cluster.trim().isEmpty) space = b;
            }
            index++;
          }
          if (clause > offset) {
            end = clause;
          } else if (space > offset) {
            end = space;
          }
        }
        // Never strand trailing whitespace or emit a silent leading clip.
        if (end >= spokenEnd) end = coverageEnd;
        while (block.text.substring(offset, end).trim().isEmpty &&
            end < coverageEnd) {
          end = ceil(end + 1);
        }
        if (end - offset > maxNarrationClipUnits) {
          throw const FormatException(
            'Narration whitespace attachment exceeds 3,000 UTF-16 units.',
          );
        }
        result.add(
          NarrationPlaybackUnit(
            chunk: NarrationChunk(
              text: block.text.substring(offset, end),
              start: position(offset),
              end: position(end),
            ),
            sentence: fallback,
          ),
        );
        offset = end;
      }
      pendingStart = coverageEnd;
    }
  }
  return List.unmodifiable(result);
}
