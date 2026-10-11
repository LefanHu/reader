import 'package:flutter/material.dart';

import 'layout/measured_block.dart';
import 'selectable_text_slice.dart';
import 'text_slice_painter.dart';

/// Paints selectable normalized text and semantics for the visible block slice.
class BlockSlice extends StatefulWidget {
  /// Borrows a block painter for the specified visible text and geometry.
  const BlockSlice({
    super.key,
    required this.block,
    required this.top,
    required this.height,
    required this.start,
    required this.end,
    required this.bottomPadding,
    this.narrationRange,
  });

  /// Measured block borrowed from the retained section layout.
  final MeasuredBlock block;

  /// Block-local clipping top, visible height, and following block gap.
  final double top, height, bottomPadding;

  /// Visible source bounds used for committed-page semantics.
  final int start, end;

  /// Source-offset decoration intersected with this slice, never user selection.
  final TextSelection? narrationRange;

  @override
  State<BlockSlice> createState() => _BlockSliceState();
}

class _BlockSliceState extends State<BlockSlice> {
  TextSlicePainter? _painter;

  @override
  Widget build(BuildContext context) {
    final block = widget.block;
    final top = widget.top;
    final height = widget.height;
    final start = widget.start;
    final end = widget.end;
    final requested = widget.narrationRange;
    final from = requested == null || requested.start < start
        ? start
        : requested.start;
    final to = requested == null || requested.end > end ? end : requested.end;
    final range = requested != null && from < to
        ? TextSelection(baseOffset: from, extentOffset: to)
        : null;
    _painter = TextSlicePainter(
      block.painter,
      top,
      height: height,
      narrationRange: range,
      highlightColor: range == null
          ? null
          : Theme.of(context).colorScheme.primary.withValues(alpha: .14),
      previous: _painter,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: widget.bottomPadding),
      child: Semantics(
        label: block.block.text.substring(start, end),
        textDirection: block.painter.textDirection,
        header: block.block.kind == 'heading',
        child: SizedBox(
          height: height,
          child: ClipRect(
            child: SelectableTextSlice(
              block: block,
              top: top,
              start: start,
              end: end,
              child: CustomPaint(painter: _painter),
            ),
          ),
        ),
      ),
    );
  }
}
