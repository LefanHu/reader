import 'package:flutter/material.dart';

import 'layout/measured_block.dart';
import 'text_slice_painter.dart';

/// Paints and exposes semantics for only the committed block slice.
class BlockSlice extends StatelessWidget {
  /// Borrows a block painter for the specified visible text and geometry.
  const BlockSlice({
    super.key,
    required this.block,
    required this.top,
    required this.height,
    required this.start,
    required this.end,
    required this.bottomPadding,
  });

  /// Measured block borrowed from the retained section layout.
  final MeasuredBlock block;

  /// Block-local clipping top, visible height, and following block gap.
  final double top, height, bottomPadding;

  /// Visible source bounds used for committed-page semantics.
  final int start, end;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: bottomPadding),
    child: Semantics(
      label: block.block.text.substring(start, end),
      textDirection: block.painter.textDirection,
      header: block.block.kind == 'heading',
      child: SizedBox(
        height: height,
        child: ClipRect(
          child: CustomPaint(painter: TextSlicePainter(block.painter, top)),
        ),
      ),
    ),
  );
}
