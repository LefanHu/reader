import '../text/grapheme_boundary.dart';
import '../text/text_position.dart';
import 'book_text_index.dart';
import 'scene_anchor.dart';

/// Releases scenes only after the viewport's leading passage passes their end.
/// End-exclusive offsets also release a final paragraph after explicit finish.
/// Unknown anchors or positions remain locked; visibility alone is insufficient.
class IllustrationGate {
  /// Stateless gate over normalized paragraph identities.
  const IllustrationGate();

  /// Both position and anchor must resolve in the same normalized document.
  bool hasPassed({
    required SceneAnchor anchor,
    required BookTextIndex index,
    required TextPosition position,
  }) {
    if (position.version != textDocumentVersion) return false;
    final anchorChapter = index.chapters
        .where(
          (c) => c.href == anchor.href && c.spineOrdinal == anchor.spineOrdinal,
        )
        .firstOrNull;
    final currentChapter = index.chapterForHref(position.sectionId);
    if (anchorChapter == null || currentChapter == null) return false;
    final anchorOrdinal = anchorChapter.paragraphs
        .where((p) => p.id == anchor.paragraphId)
        .firstOrNull
        ?.ordinal;
    final current = currentChapter.paragraphs
        .where((p) => p.id == position.blockId)
        .firstOrNull;
    if (anchorOrdinal == null ||
        current == null ||
        position.offset < 0 ||
        position.offset > current.text.length ||
        graphemeFloor(current.text, position.offset) != position.offset) {
      return false;
    }
    if (currentChapter.spineOrdinal > anchor.spineOrdinal) return true;
    return currentChapter.spineOrdinal == anchor.spineOrdinal &&
        (current.ordinal > anchorOrdinal ||
            (current.ordinal == anchorOrdinal &&
                position.offset == current.text.length));
  }
}
