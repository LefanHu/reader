import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../text_section.dart' as text;
import '../text_position.dart' as text;
import '../grapheme_boundary.dart' as text;
import '../direction.dart';
import 'measured_block.dart';
import 'text_line.dart';

/// Vertical gap after every measured block; scroll offsets and page fitting depend on it.
const double blockGap = 16.0;

/// Owns section text painters and their measured lines and pages.
class SectionLayout {
  /// Measures a section once for the supplied typography and viewport.
  SectionLayout(
    text.TextSection section,
    double width,
    this.viewportHeight,
    TextStyle style,
    TextScaler scaler, {
    this.figureBlockIds = const {},
  }) : figureHeight = math.min(width / 1.5, viewportHeight * .75) {
    var globalTop = 0.0;
    for (final block in section.blocks) {
      final painter = TextPainter(
        text: TextSpan(
          text: block.text,
          style: style.copyWith(
            fontWeight: block.kind == 'heading'
                ? FontWeight.w600
                : FontWeight.normal,
            fontStyle: block.kind == 'quote'
                ? FontStyle.italic
                : FontStyle.normal,
          ),
        ),
        textDirection: paragraphDirection(block.text, block.direction),
        textScaler: scaler,
      )..layout(maxWidth: width);
      final measured = MeasuredBlock(block, painter);
      blocks.add(measured);
      final metrics = painter.computeLineMetrics();
      // Segment each multi-line block once; snapping every line end with a
      // scan from offset zero made long blocks quadratic on the UI isolate.
      final boundaries = metrics.length > 1
          ? text.GraphemeBoundaries(block.text)
          : null;
      var start = 0;
      for (var i = 0; i < metrics.length; i++) {
        final metric = metrics[i];
        final top = metric.baseline - metric.ascent;
        final probe = painter.getPositionForOffset(
          Offset(metric.left + metric.width / 2, top + metric.height / 2),
        );
        final boundary = painter.getLineBoundary(probe);
        var end = i == metrics.length - 1
            ? block.text.length
            : boundaries!.floor(boundary.end);
        if (end < block.text.length && block.text[end] == '\n') end++;
        // LineMetrics.height is rounded; use measured top-to-top distances so
        // fractional font sizes cannot accumulate into page overflow.
        final lineHeight = i + 1 < metrics.length
            ? metrics[i + 1].baseline - metrics[i + 1].ascent - top
            : painter.height - top;
        lines.add(
          TextLine(measured, top, globalTop + top, lineHeight, start, end),
        );
        start = end;
      }
      globalTop += painter.height + blockGap;
      if (figureBlockIds.contains(block.id)) {
        lines.add(
          TextLine(
            measured,
            0,
            globalTop,
            figureHeight,
            block.text.length,
            block.text.length,
            figure: true,
          ),
        );
        globalTop += figureHeight + blockGap;
      }
    }
    var page = <TextLine>[];
    var used = 0.0;
    for (final line in lines) {
      final gap =
          page.isNotEmpty &&
              (page.last.block != line.block || page.last.figure != line.figure)
          ? blockGap
          : 0.0;
      if (page.isNotEmpty && used + gap + line.height > viewportHeight) {
        pages.add(page);
        page = [];
        used = 0;
      }
      if (page.isNotEmpty &&
          (page.last.block != line.block || page.last.figure != line.figure)) {
        used += blockGap;
      }
      page.add(line);
      used += line.height;
    }
    if (page.isNotEmpty) pages.add(page);
  }

  /// Available page height used to partition measured lines.
  final double viewportHeight;

  /// Blocks followed by an inline figure slot. Part of layout identity.
  final Set<String> figureBlockIds;

  /// Height of every figure slot: a 3:2 landscape frame that always fits on
  /// one page, so figures never split across pages.
  final double figureHeight;

  /// Blocks whose text painters are owned exclusively by this layout.
  final blocks = <MeasuredBlock>[];

  /// Measured lines in normalized reading order.
  final lines = <TextLine>[];

  /// Pages borrowing contiguous measured lines.
  final pages = <List<TextLine>>[];

  /// Finds the last text line starting at or before the complete logical anchor.
  ///
  /// Figure slots are skipped so restoration and narration following always
  /// target text lines.
  TextLine lineFor(text.TextPosition position) =>
      lines
          .where(
            (line) =>
                !line.figure &&
                line.block.block.id == position.blockId &&
                line.start <= position.offset,
          )
          .lastOrNull ??
      lines.first;

  /// Releases the resources owned by this component.
  void dispose() {
    for (final block in blocks) {
      block.painter.dispose();
    }
  }
}
