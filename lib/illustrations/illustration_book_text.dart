import '../text/document.dart';
import '../text/document_store.dart';
import '../text/text_position.dart';
import 'chapter_text_index.dart';
import 'indexed_paragraph.dart';
import 'scene_anchor.dart';

/// Illustration view of one import's normalized `TextDocument`.
///
/// Chapter prose is built on demand from the same sections and stable block
/// IDs the viewport paints; nothing is persisted, so there is no second copy
/// of the text. Only per-section block-ID sets are retained, for resolving
/// scene anchors.
class IllustrationBookText {
  IllustrationBookText._(this._documents, this.sourcePath, this.document);

  /// Loads the immutable manifest of the import at [sourcePath].
  static Future<IllustrationBookText> load(
    TextDocumentStore documents,
    String sourcePath,
  ) async => IllustrationBookText._(
    documents,
    sourcePath,
    await documents.load(sourcePath),
  );

  final TextDocumentStore _documents;

  /// Imported book file whose normalized sidecars are read.
  final String sourcePath;

  /// Immutable section manifest of the import.
  final TextDocument document;

  final Map<String, Set<String>> _blockIds = {};

  /// Number of sections, each one server chapter.
  int get chapterCount => document.sections.length;

  /// Ordinal of the section holding [position]; the first for unknown ones.
  int ordinalAt(TextPosition? position) {
    final ordinal = document.ordinalOf(position?.sectionId);
    return ordinal < 0 ? 0 : ordinal;
  }

  /// Bounded chapter payload for section [ordinal], read from disk on demand.
  Future<ChapterTextIndex> chapter(int ordinal) async {
    final summary = document.sections[ordinal];
    final section = await _documents.loadSection(sourcePath, summary.id);
    final blocks = section.blocks;
    _blockIds[section.id] ??= {for (final block in blocks) block.id};
    return ChapterTextIndex(
      href: section.id,
      spineOrdinal: ordinal,
      title: summary.title,
      language: summary.language,
      paragraphs: [
        for (var i = 0; i < blocks.length; i++)
          IndexedParagraph(
            id: blocks[i].id,
            text: blocks[i].text,
            ordinal: i,
            progression: blocks.length == 1 ? 1 : i / (blocks.length - 1),
          ),
      ],
    );
  }

  /// Whether [anchor] names an existing block of the matching section.
  ///
  /// Unknown anchors never download or render.
  Future<bool> resolves(SceneAnchor anchor) async {
    final ordinal = document.ordinalOf(anchor.href);
    if (ordinal < 0 || ordinal != anchor.spineOrdinal) return false;
    final ids = _blockIds[anchor.href] ??= {
      for (final block in (await _documents.loadSection(
        sourcePath,
        anchor.href,
      )).blocks)
        block.id,
    };
    return ids.contains(anchor.paragraphId);
  }
}
