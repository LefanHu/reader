import 'package:flutter/rendering.dart';

/// Paints a clipped slice without owning or disposing its text painter.
class TextSlicePainter extends CustomPainter {
  /// Borrows a measured painter and caches source-range boxes before painting.
  TextSlicePainter(
    this.textPainter,
    this.top, {
    required this.height,
    this.narrationRange,
    this.highlightColor,
    TextSlicePainter? previous,
  }) : highlightRects =
           previous != null &&
               identical(previous.textPainter, textPainter) &&
               previous.top == top &&
               previous.height == height &&
               previous.narrationRange == narrationRange
           ? previous.highlightRects
           : _rangeRects(textPainter, top, height, narrationRange);

  /// Painter owned and disposed by the section layout, never by this slice.
  final TextPainter textPainter;

  /// Block-local vertical origin of the visible slice.
  final double top;

  /// Visible slice extent used to clip source-range geometry.
  final double height;

  /// Source offsets already validated against the normalized block and slice.
  final TextSelection? narrationRange;

  /// Themed glyph wash, independent of user selection and text semantics.
  final Color? highlightColor;

  /// Cached separate boxes preserve mixed-direction text geometry.
  final List<Rect> highlightRects;

  static List<Rect> _rangeRects(
    TextPainter painter,
    double top,
    double height,
    TextSelection? range,
  ) {
    if (range == null || range.isCollapsed || range.start < 0) return const [];
    final clip = Rect.fromLTWH(0, 0, painter.width, height);
    final rects = <Rect>[];
    final shift = Offset(0, -top);
    for (final box in painter.getBoxesForSelection(range)) {
      final rect = box.toRect().shift(shift);
      if (rect.overlaps(clip)) rects.add(rect.intersect(clip));
    }
    return rects;
  }

  late final Paint? _highlightPaint = highlightColor == null
      ? null
      : (Paint()..color = highlightColor!);

  @override
  void paint(Canvas canvas, Size size) {
    if (_highlightPaint case final paint?) {
      for (final rect in highlightRects) {
        canvas.drawRect(rect, paint);
      }
    }
    textPainter.paint(canvas, Offset(0, -top));
  }

  @override
  bool shouldRepaint(TextSlicePainter oldDelegate) =>
      oldDelegate.textPainter != textPainter ||
      oldDelegate.top != top ||
      oldDelegate.height != height ||
      oldDelegate.narrationRange != narrationRange ||
      oldDelegate.highlightColor != highlightColor;
}
