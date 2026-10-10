import 'package:characters/characters.dart';

import 'narration_chunk.dart';
import 'text_position.dart';
import 'text_section.dart';

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
    while (offset < block.text.length) {
      var end = offset;
      var sentence = offset;
      for (final cluster in block.text.substring(offset).characters) {
        if (end + cluster.length - offset > 3000) break;
        end += cluster.length;
        if (RegExp(r'[.!?。！？]\s*$').hasMatch(cluster)) sentence = end;
      }
      // A single pathological extended grapheme cannot be split or uploaded.
      if (end == offset) {
        throw const FormatException(
          'Narration grapheme exceeds 3,000 UTF-16 units.',
        );
      }
      if (end < block.text.length && sentence > offset) end = sentence;
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
