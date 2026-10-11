import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'block_slice.dart';
import 'grapheme_boundary.dart';
import 'layout/measured_block.dart';
import 'layout/section_layout.dart';
import 'layout/text_line.dart';
import 'narration_range.dart';

/// Validates the complete narration identity before exposing block offsets.
TextSelection? narrationBlockRange({
  required NarrationRange? range,
  required int documentVersion,
  required String sectionId,
  required MeasuredBlock block,
}) {
  if (range == null ||
      range.start.version != documentVersion ||
      range.end.version != documentVersion ||
      range.start.sectionId != sectionId ||
      range.end.sectionId != sectionId ||
      range.start.blockId != block.block.id ||
      range.end.blockId != block.block.id ||
      range.start.offset < 0 ||
      range.end.offset > block.block.text.length ||
      range.start.offset >= range.end.offset ||
      graphemeFloor(block.block.text, range.start.offset) !=
          range.start.offset ||
      graphemeFloor(block.block.text, range.end.offset) != range.end.offset) {
    return null;
  }
  return TextSelection(
    baseOffset: range.start.offset,
    extentOffset: range.end.offset,
  );
}

/// Builds visible page fragments while borrowing retained line/painter owners.
List<Widget> textPageSlices(
  List<TextLine> page, {
  required int documentVersion,
  required String sectionId,
  NarrationRange? activeNarrationRange,
}) {
  final slices = <Widget>[];
  var start = 0;
  while (start < page.length) {
    var end = start + 1;
    while (end < page.length && page[end].block == page[start].block) {
      end++;
    }
    final first = page[start];
    final last = page[end - 1];
    final range = narrationBlockRange(
      range: activeNarrationRange,
      documentVersion: documentVersion,
      sectionId: sectionId,
      block: first.block,
    );
    final from = math.max(first.start, range?.start ?? first.start);
    final to = math.min(last.end, range?.end ?? first.start);
    slices.add(
      BlockSlice(
        block: first.block,
        top: first.top,
        height: last.top + last.height - first.top,
        start: first.start,
        end: last.end,
        bottomPadding: end < page.length ? 16 : 0,
        narrationRange: range != null && from < to
            ? TextSelection(baseOffset: from, extentOffset: to)
            : null,
      ),
    );
    start = end;
  }
  return slices;
}

/// Rasterizes borrowed page lines for curl previews without retaining painters.
ui.Image textPageTexture({
  required SectionLayout layout,
  required int page,
  required double width,
  required double height,
  required Color background,
}) {
  final ratio = math.min(2.0, 2048 / math.max(width, height));
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(ratio);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = background,
  );
  final lines = layout.pages[page];
  var y = 0.0;
  var start = 0;
  while (start < lines.length) {
    var end = start + 1;
    while (end < lines.length && lines[end].block == lines[start].block) {
      end++;
    }
    final first = lines[start];
    final last = lines[end - 1];
    final extent = last.top + last.height - first.top;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, y, width, extent));
    first.block.painter.paint(canvas, Offset(0, y - first.top));
    canvas.restore();
    y += extent + 16;
    start = end;
  }
  final picture = recorder.endRecording();
  try {
    return picture.toImageSync((width * ratio).ceil(), (height * ratio).ceil());
  } finally {
    picture.dispose();
  }
}
