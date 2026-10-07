import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';

import 'document.dart';

/// Increment when chunking rules change; cached speech must match exact prose.
const narrationChunkVersion = 1;

/// Exact normalized passage, bounded in UTF-16 and never across a grapheme.
class NarrationChunk {
  /// Anchors include the exclusive ending offset, even within a paragraph.
  NarrationChunk({required this.text, required this.start, required this.end})
    : digest = sha256.convert(utf8.encode(text)).toString();

  /// Prose is uploaded verbatim as data, without a second normalization pipeline.
  final String text;

  /// Complete logical anchor before any audio in this chunk has played.
  final TextPosition start;

  /// Exclusive anchor committed only after uninterrupted playback completion.
  final TextPosition end;

  /// Digest protects cache identity from changed text or chunking rules.
  final String digest;

  /// Stable identity includes anchors as equal prose can occur more than once.
  String get id => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'version': narrationChunkVersion,
            'start': start.toJson(),
            'end': end.toJson(),
            'digest': digest,
          }),
        ),
      )
      .toString();
}

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
