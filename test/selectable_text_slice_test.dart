import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/text/block_slice.dart';
import 'package:reader/text/layout/measured_block.dart';
import 'package:reader/text/selectable_text_slice.dart';
import 'package:reader/text/text_block.dart';
import 'package:reader/text/text_slice_painter.dart';

void main() {
  testWidgets('select all copies only the visible normalized slice', (
    tester,
  ) async {
    final block = _measure('Hidden\nVisible words\nAfter');
    _releaseAfterUnmount(tester, block);
    final start = block.block.text.indexOf('Visible');
    final end = block.block.text.indexOf('\nAfter');
    final top = _lineTop(block, 1);
    await _mount(
      tester,
      block,
      start: start,
      end: end,
      top: top,
      height: _lineTop(block, 2) - top,
    );
    final selectable = _selectable(tester);
    selectable.dispatchSelectionEvent(const SelectAllSelectionEvent());
    expect(selectable.getSelectedContent()!.plainText, 'Visible words');
    expect(
      selectable.getSelection(),
      SelectedContentRange(startOffset: 0, endOffset: end - start),
    );
    expect(selectable.blockId, 'block');
    expect(selectable.value.selectionRects, isNotEmpty);
    for (final rect in selectable.value.selectionRects) {
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(selectable.size.height));
    }
    final paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is TextSlicePainter,
      ),
    );
    expect(
      (paint.painter! as TextSlicePainter).textPainter,
      same(block.painter),
    );
  });

  testWidgets('word hit testing restores the clipped block-local top', (
    tester,
  ) async {
    final block = _measure('Hidden\nVisible words\nAfter');
    _releaseAfterUnmount(tester, block);
    final start = block.block.text.indexOf('Visible');
    final end = block.block.text.indexOf('\nAfter');
    final top = _lineTop(block, 1);
    await _mount(
      tester,
      block,
      start: start,
      end: end,
      top: top,
      height: _lineTop(block, 2) - top,
    );
    final selectable = _selectable(tester);
    final position = _globalFor(tester, block, start, start + 7, top);
    selectable.dispatchSelectionEvent(
      SelectWordSelectionEvent(globalPosition: position),
    );
    expect(selectable.getSelectedContent()!.plainText, 'Visible');
    expect(selectable.value.status, SelectionStatus.uncollapsed);
    expect(
      selectable.value.startSelectionPoint!.localPosition.dy,
      lessThanOrEqualTo(selectable.size.height),
    );
    expect(
      selectable.value.endSelectionPoint!.localPosition.dy,
      lessThanOrEqualTo(selectable.size.height),
    );
    selectable.dispatchSelectionEvent(
      SelectParagraphSelectionEvent(globalPosition: position),
    );
    expect(selectable.getSelectedContent()!.plainText, 'Visible words');
  });

  testWidgets('keyboard line movement stops at visible source boundaries', (
    tester,
  ) async {
    final block = _measure('Hidden\nVisible words\nAfter');
    _releaseAfterUnmount(tester, block);
    final start = block.block.text.indexOf('Visible');
    final end = block.block.text.indexOf('\nAfter');
    final top = _lineTop(block, 1);
    await _mount(
      tester,
      block,
      start: start,
      end: end,
      top: top,
      height: _lineTop(block, 2) - top,
    );
    final selectable = _selectable(tester);
    final global = _globalFor(tester, block, start, start + 7, top);
    selectable.dispatchSelectionEvent(
      SelectWordSelectionEvent(globalPosition: global),
    );
    expect(
      selectable.dispatchSelectionEvent(
        DirectionallyExtendSelectionEvent(
          dx: global.dx,
          isEnd: true,
          direction: SelectionExtendDirection.previousLine,
        ),
      ),
      SelectionResult.previous,
    );
    expect(selectable.getSelectedContent()!.plainText, '');
    expect(
      selectable.dispatchSelectionEvent(
        DirectionallyExtendSelectionEvent(
          dx: global.dx,
          isEnd: true,
          direction: SelectionExtendDirection.nextLine,
        ),
      ),
      SelectionResult.next,
    );
    expect(selectable.getSelectedContent()!.plainText, 'Visible words');
    selectable.dispatchSelectionEvent(const ClearSelectionEvent());
    selectable.dispatchSelectionEvent(
      const GranularlyExtendSelectionEvent(
        forward: false,
        isEnd: true,
        granularity: TextGranularity.line,
      ),
    );
    expect(selectable.getSelectedContent()!.plainText, 'Visible words');
  });

  testWidgets(
    'keyboard character extension never splits emoji or combining text',
    (tester) async {
      const family = '👩‍👩‍👧‍👦';
      const text = 'A${family}e\u0301Z';
      final block = _measure(text);
      _releaseAfterUnmount(tester, block);
      await _mount(tester, block);
      final selectable = _selectable(tester);
      const extend = GranularlyExtendSelectionEvent(
        forward: true,
        isEnd: true,
        granularity: TextGranularity.character,
      );
      selectable.dispatchSelectionEvent(extend);
      expect(selectable.getSelectedContent()!.plainText, 'A');
      selectable.dispatchSelectionEvent(extend);
      expect(selectable.getSelectedContent()!.plainText, 'A$family');
      selectable.dispatchSelectionEvent(extend);
      expect(selectable.getSelectedContent()!.plainText, 'A${family}e\u0301');
      selectable.dispatchSelectionEvent(
        const GranularlyExtendSelectionEvent(
          forward: false,
          isEnd: true,
          granularity: TextGranularity.character,
        ),
      );
      expect(selectable.getSelectedContent()!.plainText, 'A$family');
      selectable.dispatchSelectionEvent(const ClearSelectionEvent());
      expect(selectable.getSelectedContent(), isNull);
      expect(selectable.value.status, SelectionStatus.none);
    },
  );

  testWidgets(
    'RTL and reversed ranges copy logical source with directional handles',
    (tester) async {
      const text = 'שלום עולם';
      final block = _measure(text, direction: TextDirection.rtl);
      _releaseAfterUnmount(tester, block);
      await _mount(tester, block);
      final selectable = _selectable(tester);
      selectable.dispatchSelectionEvent(const SelectAllSelectionEvent());
      expect(selectable.getSelectedContent()!.plainText, text);
      expect(
        selectable.value.startSelectionPoint!.handleType,
        TextSelectionHandleType.right,
      );
      expect(
        selectable.value.endSelectionPoint!.handleType,
        TextSelectionHandleType.left,
      );
      final render = tester.renderObject<RenderBox>(
        find.byType(SelectableTextSlice),
      );
      // Reverse the source range using positions beyond the slice vertically;
      // bidi visual corners must not substitute for logical source edges.
      selectable.dispatchSelectionEvent(
        SelectionEdgeUpdateEvent.forStart(
          globalPosition: render.localToGlobal(
            Offset(0, render.size.height + 10),
          ),
        ),
      );
      selectable.dispatchSelectionEvent(
        SelectionEdgeUpdateEvent.forEnd(
          globalPosition: render.localToGlobal(const Offset(0, -10)),
        ),
      );
      expect(selectable.getSelectedContent()!.plainText, text);
      expect(selectable.getSelection()!.startOffset, text.length);
      expect(selectable.getSelection()!.endOffset, 0);
      expect(
        selectable.value.startSelectionPoint!.handleType,
        TextSelectionHandleType.left,
      );
      expect(
        selectable.value.endSelectionPoint!.handleType,
        TextSelectionHandleType.right,
      );
    },
  );

  testWidgets(
    'slice replacement clears selection without disposing its painter',
    (tester) async {
      final block = _measure('First\nSecond');
      _releaseAfterUnmount(tester, block);
      await _mount(tester, block);
      final selectable = _selectable(tester);
      selectable.dispatchSelectionEvent(const SelectAllSelectionEvent());
      final top = _lineTop(block, 1);
      await _mount(
        tester,
        block,
        start: 6,
        end: block.block.text.length,
        top: top,
        height: block.painter.height - top,
      );
      expect(_selectable(tester), same(selectable));
      expect(selectable.getSelectedContent(), isNull);
      expect(selectable.value.status, SelectionStatus.none);
      selectable.dispatchSelectionEvent(const SelectAllSelectionEvent());
      expect(selectable.getSelectedContent()!.plainText, 'Second');
      expect(
        block.painter.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 5),
        ),
        isNotEmpty,
      );
    },
  );

  testWidgets(
    'SelectionArea joins adjacent visible slices without extra text',
    (tester) async {
      final block = _measure('First line\nSecond line');
      _releaseAfterUnmount(tester, block);
      final top = _lineTop(block, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: SelectionArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 260,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _slice(block, start: 0, end: 11, top: 0, height: top),
                    _slice(
                      block,
                      start: 11,
                      end: block.block.text.length,
                      top: top,
                      height: block.painter.height - top,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final region = tester.state<SelectableRegionState>(
        find.byType(SelectableRegion),
      );
      region.selectAll(SelectionChangedCause.keyboard);
      await tester.pump();
      final slices = find
          .byType(SelectableTextSlice)
          .evaluate()
          .map((element) => element.renderObject! as BookTextSelectable)
          .toList();
      expect(slices, hasLength(2));
      expect(
        slices.map((slice) => slice.getSelectedContent()!.plainText).join(),
        block.block.text,
      );
      expect(
        slices.every((slice) => slice.value.selectionRects.isNotEmpty),
        isTrue,
      );
    },
  );
}

MeasuredBlock _measure(
  String text, {
  TextDirection direction = TextDirection.ltr,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: const TextStyle(fontSize: 20, height: 1)),
    textDirection: direction,
  )..layout(maxWidth: 260);
  return MeasuredBlock(TextBlock(id: 'block', text: text), painter);
}

void _releaseAfterUnmount(WidgetTester tester, MeasuredBlock block) {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    block.painter.dispose();
  });
}

double _lineTop(MeasuredBlock block, int line) {
  final metric = block.painter.computeLineMetrics()[line];
  return metric.baseline - metric.ascent;
}

Widget _slice(
  MeasuredBlock block, {
  int start = 0,
  int? end,
  double top = 0,
  double? height,
}) => BlockSlice(
  block: block,
  top: top,
  height: height ?? block.painter.height,
  start: start,
  end: end ?? block.block.text.length,
  bottomPadding: 0,
);

Future<void> _mount(
  WidgetTester tester,
  MeasuredBlock block, {
  int start = 0,
  int? end,
  double top = 0,
  double? height,
}) => tester.pumpWidget(
  MaterialApp(
    home: SelectionArea(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 260,
          child: _slice(
            block,
            start: start,
            end: end,
            top: top,
            height: height,
          ),
        ),
      ),
    ),
  ),
);

BookTextSelectable _selectable(WidgetTester tester) =>
    tester.renderObject(find.byType(SelectableTextSlice)) as BookTextSelectable;

Offset _globalFor(
  WidgetTester tester,
  MeasuredBlock block,
  int start,
  int end,
  double top,
) {
  final box = block.painter
      .getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: end))
      .first;
  final render = tester.renderObject<RenderBox>(
    find.byType(SelectableTextSlice),
  );
  return render.localToGlobal(box.toRect().center - Offset(0, top));
}
