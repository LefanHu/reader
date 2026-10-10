import 'package:flutter/rendering.dart';

/// Paints a clipped slice without owning or disposing its text painter.
class TextSlicePainter extends CustomPainter {
  /// Borrows a measured painter and shifts its block-local clipping origin.
  TextSlicePainter(this.textPainter, this.top);

  /// Painter owned and disposed by the section layout, never by this slice.
  final TextPainter textPainter;

  /// Block-local vertical origin of the visible slice.
  final double top;
  @override
  void paint(Canvas canvas, Size size) =>
      textPainter.paint(canvas, Offset(0, -top));
  @override
  bool shouldRepaint(TextSlicePainter oldDelegate) =>
      oldDelegate.textPainter != textPainter || oldDelegate.top != top;
}
