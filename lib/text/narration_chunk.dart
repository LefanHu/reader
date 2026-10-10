import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'text_position.dart';

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
