import 'section_summary.dart';
import 'text_contents_entry.dart';
import 'text_position.dart';
import 'text_section.dart';

/// Document manifest; prose is loaded one bounded section at a time.
class TextDocument {
  /// Metadata is immutable after the staged import commits.
  TextDocument({
    required this.title,
    required this.authors,
    required this.sections,
    required this.contents,
    this.language,
    this.identifier,
  });

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

  /// Section ID to ordinal, built once because the manifest is immutable.
  late final Map<String, int> _ordinals = {
    for (var i = 0; i < sections.length; i++) sections[i].id: i,
  };

  /// UTF-16 units before each section; the last entry is the document length.
  late final List<int> _starts = _prefix();

  List<int> _prefix() {
    final starts = <int>[0];
    for (final section in sections) {
      starts.add(starts.last + section.length);
    }
    return starts;
  }

  /// Document size for normalized reading progress.
  int get length => _starts.last;

  /// Ordinal of the section with [sectionId], or -1 when it is unknown.
  int ordinalOf(String? sectionId) => _ordinals[sectionId] ?? -1;

  /// Progress derives from source text, independent of viewport dimensions.
  double progress(TextSection section, TextPosition position) {
    final ordinal = ordinalOf(section.id);
    if (ordinal < 0 || length == 0) return 0;
    var units = _starts[ordinal];
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
    'title': title,
    'authors': authors,
    if (language != null) 'language': language,
    if (identifier != null) 'identifier': identifier,
    'sections': sections.map((item) => item.toJson()).toList(),
    'contents': contents.map((item) => item.toJson()).toList(),
  };

  /// Restores a manifest written by [toJson].
  factory TextDocument.fromJson(Map<String, dynamic> json) {
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
