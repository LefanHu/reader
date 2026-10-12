import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/text/block_slice.dart';
import 'package:reader/text/layout/section_layout.dart';
import 'package:reader/text/layout/section_layout_cache.dart';
import 'package:reader/text/text_block.dart' as text;
import 'package:reader/text/text_page_slices.dart';
import 'package:reader/text/text_position.dart' as text;
import 'package:reader/text/text_section.dart' as text;

const _width = 200.0;
const _height = 300.0;
const _style = TextStyle(fontSize: 16, height: 1.4);

text.TextSection _section() => text.TextSection(
  id: 's0',
  blocks: [
    text.TextBlock(id: 'a', text: 'Alpha paragraph with words. ' * 12),
    const text.TextBlock(id: 'b', text: 'Beta short.'),
    text.TextBlock(id: 'c', text: 'Gamma paragraph with more words. ' * 10),
  ],
);

SectionLayout _layout(Set<String> figures, {double height = _height}) {
  final layout = SectionLayout(
    _section(),
    _width,
    height,
    _style,
    TextScaler.noScaling,
    figureBlockIds: figures,
  );
  addTearDown(layout.dispose);
  return layout;
}

void main() {
  testWidgets(
    'a figure line follows its block with a 3:2 frame that fits a page',
    (tester) async {
      final layout = _layout({'a'});
      final figures = layout.lines.where((line) => line.figure).toList();
      expect(figures, hasLength(1));
      final figure = figures.single;
      expect(figure.block.block.id, 'a');
      expect(figure.height, math.min(_width / 1.5, _height * .75));
      expect(layout.lines[layout.lines.indexOf(figure) - 1].figure, isFalse);
      expect(figure.start, figure.block.block.text.length);
      expect(figure.end, figure.block.block.text.length);
    },
  );

  testWidgets('a short viewport caps the figure at three quarters of a page', (
    tester,
  ) async {
    final layout = _layout({'a'}, height: 120);
    expect(layout.figureHeight, 90);
  });

  testWidgets('no page overflows and a figure never splits across pages', (
    tester,
  ) async {
    final layout = _layout({'a', 'b', 'c'});
    for (final page in layout.pages) {
      var used = 0.0;
      for (var i = 0; i < page.length; i++) {
        final line = page[i];
        if (i > 0 &&
            (page[i - 1].block != line.block ||
                page[i - 1].figure != line.figure)) {
          used += blockGap;
        }
        used += line.height;
      }
      expect(used, lessThanOrEqualTo(_height + 1e-9));
    }
    expect(layout.lines.where((l) => l.figure), hasLength(3));
    for (final line in layout.lines.where((l) => l.figure)) {
      expect(layout.pages.where((p) => p.contains(line)), hasLength(1));
    }
  });

  testWidgets('the next block starts after the figure slot and its gaps', (
    tester,
  ) async {
    final plain = _layout({});
    final withFigure = _layout({'a'});
    final nextPlain = plain.lines.firstWhere((l) => l.block.block.id == 'b');
    final nextFigure = withFigure.lines.firstWhere(
      (l) => l.block.block.id == 'b',
    );
    expect(
      nextFigure.globalTop - nextPlain.globalTop,
      closeTo(withFigure.figureHeight + blockGap, 1e-9),
    );
  });

  testWidgets('position lookup always targets a text line', (tester) async {
    final layout = _layout({'a'});
    final text0 = layout.blocks.first.block.text;
    final line = layout.lineFor(
      text.TextPosition(sectionId: 's0', blockId: 'a', offset: text0.length),
    );
    expect(line.figure, isFalse);
    expect(line.block.block.id, 'a');
    final figure = layout.lines.firstWhere((l) => l.figure);
    expect(
      figure.position('s0'),
      text.TextPosition(sectionId: 's0', blockId: 'a', offset: text0.length),
    );
  });

  testWidgets('layout identity changes with the figure set', (tester) async {
    final cache = SectionLayoutCache();
    addTearDown(cache.dispose);
    Object key(Set<String> figures) => cache.keyFor(
      section: _section(),
      width: _width,
      height: _height,
      style: _style,
      scaler: TextScaler.noScaling,
      figureBlockIds: figures,
    );
    expect(key({'a'}), isNot(key({})));
    expect(key({'a'}), isNot(key({'a', 'b'})));
    expect(key({'a', 'b'}), key({'b', 'a'}));
  });

  testWidgets('scroll slices sum to the layout extent plus a viewport tail', (
    tester,
  ) async {
    final layout = _layout({'a', 'c'});
    var total = 0.0;
    for (final widget in scrollSectionSlices(
      layout,
      documentVersion: 1,
      sectionId: 's0',
    )) {
      total += switch (widget) {
        BlockSlice() => widget.height + widget.bottomPadding,
        Padding(padding: final EdgeInsets padding, child: SizedBox box) =>
          box.height! + padding.bottom,
        SizedBox() => widget.height!,
        _ => throw StateError('Unexpected slice ${widget.runtimeType}'),
      };
    }
    final last = layout.lines.last;
    expect(
      total,
      closeTo(
        last.globalTop + last.height + blockGap + layout.viewportHeight,
        1e-6,
      ),
    );
  });
}
