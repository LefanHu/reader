import 'grapheme_boundary.dart';
import 'text_block.dart';
import 'text_position.dart';

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
