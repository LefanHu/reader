import 'dart:convert';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';

import 'document.dart';
import 'parsed_text_book.dart';
import 'parser_limits.dart';
import 'section_summary.dart';
import 'text_block.dart';
import 'text_contents_entry.dart';
import 'text_position.dart';
import 'text_section.dart';

/// Shared TXT/EPUB normalization owner preserving stable section and block IDs.
class NormalizedTextBuilder {
  /// Uses the source content hash when assigning deterministic block IDs.
  NormalizedTextBuilder(this.hash);

  /// Source content hash used by the block identity scheme.
  final String hash;

  /// Normalized sections in source reading order.
  final sections = <TextSection>[];

  /// Metadata summaries paired with the normalized sections.
  final summaries = <SectionSummary>[];

  /// Appends bounded grapheme-safe blocks and records source navigation targets.
  void add(
    List<TextBlock> sourceBlocks, {
    required String title,
    required String source,
    String? language,
    Map<String, int> sourceIds = const {},
    Map<String, TextPosition>? targets,
  }) {
    var blocks = <TextBlock>[];
    var length = 0;
    void commit() {
      if (blocks.isEmpty) return;
      final id = 's${sections.length}';
      sections.add(TextSection(id: id, blocks: blocks));
      summaries.add(
        SectionSummary(
          id: id,
          title: summaries.any((item) => item.source == source)
              ? '$title (continued)'
              : title,
          source: source,
          length: length,
          language: language,
        ),
      );
      blocks = [];
      length = 0;
    }

    for (var ordinal = 0; ordinal < sourceBlocks.length; ordinal++) {
      final block = sourceBlocks[ordinal];
      final pieces = <String>[];
      var buffer = StringBuffer();
      for (final cluster in block.text.characters) {
        if (cluster.length > maxBlockCharacters) {
          throw const FormatException(
            'A single text character exceeds the paragraph limit.',
          );
        }
        if (buffer.length + cluster.length > maxBlockCharacters) {
          pieces.add(buffer.toString());
          buffer = StringBuffer();
        }
        buffer.write(cluster);
      }
      if (buffer.isNotEmpty) pieces.add(buffer.toString());
      for (var piece = 0; piece < pieces.length; piece++) {
        final text = pieces[piece];
        if (length + text.length > maxSectionCharacters ||
            blocks.length >= 2000) {
          commit();
        }
        final sectionId = 's${sections.length}';
        final id = sha256
            .convert(utf8.encode('$hash:$source:$ordinal:$piece'))
            .toString()
            .substring(0, 24);
        final position = TextPosition(sectionId: sectionId, blockId: id);
        targets?.putIfAbsent(source, () => position);
        if (piece == 0) {
          for (final entry in sourceIds.entries.where(
            (entry) => entry.value == ordinal,
          )) {
            targets?.putIfAbsent('$source#${entry.key}', () => position);
          }
        }
        blocks.add(
          TextBlock(
            id: id,
            text: text,
            kind: block.kind,
            direction: block.direction,
            sourceId: piece == 0
                ? sourceIds.entries
                      .where((entry) => entry.value == ordinal)
                      .firstOrNull
                      ?.key
                : null,
          ),
        );
        length += text.length;
      }
    }
    commit();
    if (sections.length > 10000) {
      throw const FormatException('The book contains too many sections.');
    }
  }

  /// Produces the parsed manifest and supplies section contents when absent.
  ParsedTextBook finish(
    String title,
    List<String> authors, {
    String? language,
    String? identifier,
    List<TextContentsEntry>? contents,
    Uint8List? cover,
    String coverExtension = 'jpg',
  }) {
    if (sections.isEmpty) {
      throw const FormatException('This book has no readable text.');
    }
    return ParsedTextBook(
      TextDocument(
        title: title,
        authors: authors,
        sections: summaries,
        contents: contents?.isNotEmpty == true
            ? contents!
            : [
                for (var i = 0; i < sections.length; i++)
                  TextContentsEntry(
                    title: summaries[i].title,
                    position: sections[i].start,
                  ),
              ],
        language: language,
        identifier: identifier,
      ),
      sections,
      cover: cover,
      coverExtension: coverExtension,
    );
  }
}
