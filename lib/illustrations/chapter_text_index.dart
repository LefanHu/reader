// Persisted field meanings and lifecycle invariants are documented per model.
// ignore_for_file: public_member_api_docs

import 'indexed_paragraph.dart';

/// Ordered normalized section and deterministic server paragraph mappings.
class ChapterTextIndex {
  const ChapterTextIndex({
    required this.href,
    required this.spineOrdinal,
    required this.title,
    required this.paragraphs,
    this.language,
  });

  /// Normalized section ID used as the backend resource identifier.
  final String href;
  final int spineOrdinal;
  final String? title;
  final String? language;
  final List<IndexedParagraph> paragraphs;

  Map<String, dynamic> toJson() => {
    'href': href,
    'spineOrdinal': spineOrdinal,
    if (title != null) 'title': title,
    if (language != null) 'language': language,
    'paragraphs': paragraphs.map((item) => item.toJson()).toList(),
  };

  factory ChapterTextIndex.fromJson(Map<String, dynamic> json) =>
      ChapterTextIndex(
        href: json['href'] as String,
        spineOrdinal: (json['spineOrdinal'] as num).round(),
        title: json['title'] as String?,
        language: json['language'] as String?,
        paragraphs: (json['paragraphs'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map(
              (item) => IndexedParagraph.fromJson(item.cast<String, dynamic>()),
            )
            .toList(),
      );
}
