import 'section_summary.dart';
import 'text_contents_entry.dart';
import 'text_position.dart';
import 'text_section.dart';

/// Versioned document manifest; prose is loaded one bounded section at a time.
class TextDocument {
  /// Metadata is immutable after the staged import commits.
  const TextDocument({
    required this.title,
    required this.authors,
    required this.sections,
    required this.contents,
    this.language,
    this.identifier,
    this.version = textDocumentVersion,
  });

  /// Normalization version required by saved positions.
  final int version;

  /// Publication title or TXT filename fallback.
  final String title;

  /// Normalized publication authors.
  final List<String> authors;

  /// Primary source language hint.
  final String? language;

  /// Optional source publication identifier.
  final String? identifier;

  /// Ordered section summaries, always nonempty.
  final List<SectionSummary> sections;

  /// Nested, resolved table of contents.
  final List<TextContentsEntry> contents;

  /// Document size for normalized reading progress.
  int get length => sections.fold(0, (sum, section) => sum + section.length);

  /// Progress derives from source text, independent of viewport dimensions.
  double progress(TextSection section, TextPosition position) {
    final ordinal = sections.indexWhere((item) => item.id == section.id);
    if (ordinal < 0 || length == 0) return 0;
    var units = sections
        .take(ordinal)
        .fold(0, (sum, item) => sum + item.length);
    final resolved = section.resolve(position);
    for (final block in section.blocks) {
      if (block.id == resolved.blockId) {
        units += resolved.offset;
        break;
      }
      units += block.text.length;
    }
    return (units / length).clamp(0, 1);
  }

  /// Serializable manifest containing no chapter prose.
  Map<String, dynamic> toJson() => {
    'version': version,
    'title': title,
    'authors': authors,
    if (language != null) 'language': language,
    if (identifier != null) 'identifier': identifier,
    'sections': sections.map((item) => item.toJson()).toList(),
    'contents': contents.map((item) => item.toJson()).toList(),
  };

  /// Rejects unknown document versions instead of misinterpreting positions.
  factory TextDocument.fromJson(Map<String, dynamic> json) {
    if (json['version'] != textDocumentVersion) {
      throw const FormatException('Unsupported text document version.');
    }
    final document = TextDocument(
      title: json['title'] as String,
      authors: (json['authors'] as List).cast<String>(),
      language: json['language'] as String?,
      identifier: json['identifier'] as String?,
      sections: (json['sections'] as List)
          .map(
            (item) =>
                SectionSummary.fromJson((item as Map).cast<String, dynamic>()),
          )
          .toList(),
      contents: (json['contents'] as List)
          .map(
            (item) => TextContentsEntry.fromJson(
              (item as Map).cast<String, dynamic>(),
            ),
          )
          .toList(),
    );
    if (document.sections.isEmpty ||
        document.sections.any(
          (section) =>
              section.length <= 0 || !RegExp(r'^s[0-9]+$').hasMatch(section.id),
        ) ||
        document.sections.map((section) => section.id).toSet().length !=
            document.sections.length) {
      throw const FormatException(
        'Invalid normalized document. Reimport this book.',
      );
    }
    return document;
  }
}
