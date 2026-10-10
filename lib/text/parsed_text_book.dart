import 'dart:typed_data';

import 'document.dart';
import 'text_section.dart';

/// Isolate-safe parsed import; sections are persisted separately at commit.
class ParsedTextBook {
  /// The cover is local archive data and never fetched over the network.
  const ParsedTextBook(
    this.document,
    this.sections, {
    this.cover,
    this.coverExtension = 'jpg',
  });

  /// Small immutable metadata manifest.
  final TextDocument document;

  /// Normalized text ready for per-section persistence.
  final List<TextSection> sections;

  /// Optional bounded local cover bytes.
  final Uint8List? cover;

  /// Extension chosen from the declared cover MIME type.
  final String coverExtension;
}
