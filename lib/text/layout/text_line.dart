import '../text_position.dart' as text;
import 'measured_block.dart';

/// A measured line borrowing its block and preserving logical offsets.
class TextLine {
  /// Records measured coordinates and normalized source offsets.
  TextLine(
    this.block,
    this.top,
    this.globalTop,
    this.height,
    this.start,
    this.end,
  );

  /// Borrowed block containing this line.
  final MeasuredBlock block;

  /// Block-local top, section-local top, and measured height.
  final double top, globalTop, height;

  /// UTF-16 source bounds aligned to normalized grapheme boundaries.
  final int start, end;

  /// Creates the complete logical anchor at this line's leading offset.
  text.TextPosition position(String section) => text.TextPosition(
    sectionId: section,
    blockId: block.block.id,
    offset: start,
  );
}
