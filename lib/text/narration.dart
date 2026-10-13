import 'grapheme_boundary.dart';
import 'narration_chunk.dart';
import 'text_position.dart';
import 'text_section.dart';

final _sentenceEnd = RegExp(r'[.!?。！？]\s*$');

/// Chunks one normalized section, preferring paragraphs then sentence endings.
/// Starting at a committed anchor yields an exact suffix rather than rereading
/// earlier prose. Each paragraph keeps its original stable block identity.
List<NarrationChunk> narrationChunks(
  TextSection section, {
  TextPosition? from,
}) {
  final anchor = from == null ? section.start : section.resolve(from);
  final chunks = <NarrationChunk>[];
  var started = false;
  for (final block in section.blocks) {
    if (block.id == anchor.blockId) started = true;
    if (!started) continue;
    var offset = block.id == anchor.blockId ? anchor.offset : 0;
    // Segment each block once; clips walk boundary indexes instead of
    // re-segmenting a copied suffix per clip.
    // Anchors resolve to grapheme boundaries, so [index] names [offset].
    final graphemes = GraphemeBoundaries(block.text);
    final boundaries = graphemes.offsets;
    var index = graphemes.floorIndex(offset);
    while (offset < block.text.length) {
      var end = offset;
      var sentence = offset;
      var sentenceIndex = index;
      for (; index + 1 < boundaries.length; index++) {
        final next = boundaries[index + 1];
        if (next - offset > maxNarrationClipUnits) break;
        if (_sentenceEnd.hasMatch(block.text.substring(end, next))) {
          sentence = next;
          sentenceIndex = index + 1;
        }
        end = next;
      }
      // A single pathological extended grapheme cannot be split or uploaded.
      if (end == offset) {
        throw const FormatException(
          'Narration grapheme exceeds 3,000 UTF-16 units.',
        );
      }
      if (end < block.text.length && sentence > offset) {
        end = sentence;
        index = sentenceIndex;
      }
      chunks.add(
        NarrationChunk(
          text: block.text.substring(offset, end),
          start: TextPosition(
            sectionId: section.id,
            blockId: block.id,
            offset: offset,
          ),
          end: TextPosition(
            sectionId: section.id,
            blockId: block.id,
            offset: end,
          ),
        ),
      );
      offset = end;
    }
  }
  return chunks;
}
