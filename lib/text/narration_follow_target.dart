import 'layout/section_layout.dart';
import 'text_position.dart';

/// Whether a complete source anchor's measured line is already readable.
/// This is presentation geometry only; it never resolves or commits progress.
bool narrationTargetVisible({
  required TextPosition target,
  required String sectionId,
  required SectionLayout layout,
  required int? page,
  required double scrollOffset,
  required double viewportExtent,
}) {
  if (target.sectionId != sectionId) {
    return false;
  }
  final block = layout.blocks
      .where((item) => item.block.id == target.blockId)
      .firstOrNull;
  if (block == null ||
      target.offset < 0 ||
      target.offset > block.block.text.length) {
    return false;
  }
  final line = layout.lineFor(target);
  if (page != null) {
    return page >= 0 &&
        page < layout.pages.length &&
        layout.pages[page].contains(line);
  }
  // Require the complete line, rather than a sliver at a viewport edge.
  return line.globalTop >= scrollOffset &&
      line.globalTop + line.height <= scrollOffset + viewportExtent;
}
