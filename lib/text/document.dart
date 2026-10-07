import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:characters/characters.dart';

/// Normalization version; positions are valid only for this document format.
const textDocumentVersion = 1;

/// Layout-independent leading reading position, never a page or pixel index.
class TextPosition {
  /// Offsets use UTF-16, matching Flutter, and must be grapheme boundaries.
  const TextPosition({
    required this.sectionId,
    required this.blockId,
    this.offset = 0,
    this.version = textDocumentVersion,
  });

  /// Normalization version used to reject incompatible saved positions.
  final int version;

  /// Stable normalized section identifier.
  final String sectionId;

  /// Stable normalized block identifier.
  final String blockId;

  /// UTF-16 offset within the block, clamped before layout or persistence.
  final int offset;

  /// Durable position representation.
  Map<String, dynamic> toJson() => {
    'version': version,
    'sectionId': sectionId,
    'blockId': blockId,
    'offset': offset,
  };

  /// Restores a position; validation against its document happens on opening.
  factory TextPosition.fromJson(Map<String, dynamic> json) => TextPosition(
    version: json['version'] as int,
    sectionId: json['sectionId'] as String,
    blockId: json['blockId'] as String,
    offset: json['offset'] as int,
  );
  @override
  bool operator ==(Object other) =>
      other is TextPosition &&
      version == other.version &&
      sectionId == other.sectionId &&
      blockId == other.blockId &&
      offset == other.offset;
  @override
  int get hashCode => Object.hash(version, sectionId, blockId, offset);
  @override
  String toString() => 'TextPosition(v$version, $sectionId/$blockId@$offset)';
}

/// Snaps backward so restoration and pagination never bisect a grapheme.
int graphemeFloor(String text, int offset) {
  final target = offset.clamp(0, text.length);
  var boundary = 0;
  for (final cluster in text.characters) {
    final next = boundary + cluster.length;
    if (next > target) break;
    boundary = next;
  }
  return boundary;
}

/// Normalized paragraph or heading shared verbatim with illustration jobs.
class TextBlock {
  /// Source fragments retain navigation targets after publisher markup is lost.
  const TextBlock({
    required this.id,
    required this.text,
    this.kind = 'paragraph',
    this.direction,
    this.sourceId,
  });

  /// Stable content-addressed block identifier.
  final String id;

  /// Unicode text; explicit line breaks are retained.
  final String text;

  /// Structural style: paragraph, heading, list, quote, or pre.
  final String kind;

  /// Explicit inherited source direction, otherwise first-strong detection.
  final String? direction;

  /// Original HTML ID used by nested EPUB navigation.
  final String? sourceId;

  /// Serializable normalized block.
  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'kind': kind,
    if (direction != null) 'direction': direction,
    if (sourceId != null) 'sourceId': sourceId,
  };

  /// Restores a block from a section sidecar.
  factory TextBlock.fromJson(Map<String, dynamic> json) => TextBlock(
    id: json['id'] as String,
    text: json['text'] as String,
    kind: json['kind'] as String,
    direction: json['direction'] as String?,
    sourceId: json['sourceId'] as String?,
  );
}

/// One bounded section loaded independently of the rest of the book.
class TextSection {
  /// Sections obey the illustration API's prose and paragraph bounds.
  const TextSection({required this.id, required this.blocks});

  /// Stable section identifier, also used as the illustration resource href.
  final String id;

  /// Ordered nonempty blocks.
  final List<TextBlock> blocks;

  /// UTF-16 size used for document-wide progress.
  int get length => blocks.fold(0, (sum, block) => sum + block.text.length);

  /// Canonical first passage of the section.
  TextPosition get start =>
      TextPosition(sectionId: id, blockId: blocks.first.id);

  /// Validates identity and snaps the offset to a safe text boundary.
  TextPosition resolve(TextPosition position) {
    final block = blocks
        .where((block) => block.id == position.blockId)
        .firstOrNull;
    if (position.version != textDocumentVersion ||
        position.sectionId != id ||
        block == null) {
      return start;
    }
    return TextPosition(
      sectionId: id,
      blockId: block.id,
      offset: graphemeFloor(block.text, position.offset),
    );
  }

  /// Normalized section representation persisted at import time.
  Map<String, dynamic> toJson() => {
    'id': id,
    'blocks': blocks.map((block) => block.toJson()).toList(),
  };

  /// Restores the bounded content of a single section.
  factory TextSection.fromJson(Map<String, dynamic> json) {
    final section = TextSection(
      id: json['id'] as String,
      blocks: (json['blocks'] as List)
          .map(
            (item) => TextBlock.fromJson((item as Map).cast<String, dynamic>()),
          )
          .toList(),
    );
    if (section.blocks.isEmpty ||
        section.blocks.any((block) => block.id.isEmpty || block.text.isEmpty) ||
        section.blocks.map((block) => block.id).toSet().length !=
            section.blocks.length) {
      throw const FormatException(
        'Invalid normalized section. Reimport this book.',
      );
    }
    return section;
  }
}

/// Small section metadata retained while section text stays on disk.
class SectionSummary {
  /// Stores source mapping and progress without keeping prose in memory.
  const SectionSummary({
    required this.id,
    required this.title,
    required this.source,
    required this.length,
    this.language,
  });

  /// Generated section resource identifier.
  final String id;

  /// Display title from EPUB metadata or deterministic TXT section numbering.
  final String title;

  /// Original archive resource path, or TXT section identifier.
  final String source;

  /// Number of normalized UTF-16 units in this section.
  final int length;

  /// Source language hint, if present.
  final String? language;

  /// Serializable summary used by document.json.
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'source': source,
    'length': length,
    if (language != null) 'language': language,
  };

  /// Restores a summary without loading its prose.
  factory SectionSummary.fromJson(Map<String, dynamic> json) => SectionSummary(
    id: json['id'] as String,
    title: json['title'] as String,
    source: json['source'] as String,
    length: json['length'] as int,
    language: json['language'] as String?,
  );
}

/// Nested navigation target resolved to normalized text rather than HTML.
class TextContentsEntry {
  /// Container entries can have children without a readable target.
  const TextContentsEntry({
    required this.title,
    this.position,
    this.children = const [],
  });

  /// Reader-visible navigation label.
  final String title;

  /// Resolved paragraph target, if the source link is readable.
  final TextPosition? position;

  /// Nested navigation structure retained from EPUB navigation.
  final List<TextContentsEntry> children;

  /// Durable navigation tree.
  Map<String, dynamic> toJson() => {
    'title': title,
    if (position != null) 'position': position!.toJson(),
    'children': children.map((item) => item.toJson()).toList(),
  };

  /// Restores a navigation subtree.
  factory TextContentsEntry.fromJson(Map<String, dynamic> json) =>
      TextContentsEntry(
        title: json['title'] as String,
        position: json['position'] == null
            ? null
            : TextPosition.fromJson(
                (json['position'] as Map).cast<String, dynamic>(),
              ),
        children: (json['children'] as List)
            .map(
              (item) => TextContentsEntry.fromJson(
                (item as Map).cast<String, dynamic>(),
              ),
            )
            .toList(),
      );
}

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

/// Disk boundary used by rendering and illustration indexing alike.
class TextDocumentStore {
  /// Loads only the immutable document manifest.
  Future<TextDocument> load(String sourcePath) async {
    final path = '${File(sourcePath).parent.path}/document.json';
    return Isolate.run(
      () async => TextDocument.fromJson(
        (jsonDecode(await File(path).readAsString()) as Map)
            .cast<String, dynamic>(),
      ),
    );
  }

  /// Loads a generated section ID; source paths never become filesystem paths.
  Future<TextSection> loadSection(String sourcePath, String id) async {
    if (!RegExp(r'^s[0-9]+$').hasMatch(id)) {
      throw const FormatException('Invalid section ID.');
    }
    final path = '${File(sourcePath).parent.path}/text/$id.json';
    return Isolate.run(() async {
      final section = TextSection.fromJson(
        (jsonDecode(await File(path).readAsString()) as Map)
            .cast<String, dynamic>(),
      );
      if (section.id != id) {
        throw const FormatException(
          'Section identity mismatch. Reimport this book.',
        );
      }
      return section;
    });
  }
}
