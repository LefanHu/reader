import 'indexed_paragraph.dart';

/// One normalized section submitted as a server chapter, with stable block IDs
/// as paragraph identities. Built on demand from the `TextDocument`; never
/// persisted.
class ChapterTextIndex {
  /// Paragraphs are the section's blocks in order, verbatim.
  const ChapterTextIndex({
    required this.href,
    required this.spineOrdinal,
    required this.title,
    required this.paragraphs,
    this.language,
  });

  /// Normalized section ID used as the backend resource identifier.
  final String href;

  /// Zero-based section ordinal, the server chapter number.
  final int spineOrdinal;

  /// Section title, if the source provided one.
  final String? title;

  /// Section language hint.
  final String? language;

  /// Ordered blocks of the section.
  final List<IndexedParagraph> paragraphs;
}
