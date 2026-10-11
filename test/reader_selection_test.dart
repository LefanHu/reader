import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/preferences/reader_settings.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/text/block_slice.dart';
import 'package:reader/text/selectable_text_slice.dart';
import 'package:reader/text/text_block.dart' as text;
import 'package:reader/text/text_section.dart' as text;
import 'package:reader/text/text_position.dart' as text;

import 'support/memory_document_store.dart';
import 'support/text_viewport_harness.dart';

void main() {
  for (final mode in ReadingMode.values) {
    testWidgets(
      '${mode.name} mouse selection leaves the committed anchor unchanged',
      (tester) async {
        final harness = TextViewportHarness(
          store: MemoryDocumentStore(
            sections: [
              text.TextSection(
                id: 's0',
                blocks: [
                  text.TextBlock(
                    id: 'p0',
                    text: 'Dictionary lookup stays local. ' * 40,
                  ),
                ],
              ),
            ],
          ),
        );
        harness.settings.value = ReaderSettings(mode: mode);
        await harness.mount(tester);
        final anchor = harness.navigation.leadingPosition;
        final slice = tester.widget<BlockSlice>(find.byType(BlockSlice).first);
        final render = tester.renderObject<RenderBox>(
          find.byType(BlockSlice).first,
        );
        final box = slice.block.painter
            .getBoxesForSelection(
              const TextSelection(baseOffset: 0, extentOffset: 10),
            )
            .single
            .toRect()
            .shift(render.localToGlobal(Offset(0, -slice.top)));
        final gesture = await tester.startGesture(
          Offset(box.left + .1, box.center.dy),
          kind: PointerDeviceKind.mouse,
        );
        var released = false;
        try {
          await gesture.moveTo(Offset(box.right + .1, box.center.dy));
          await tester.pump();
          await gesture.up();
          released = true;
          await tester.pumpAndSettle();
        } finally {
          if (!released) await gesture.cancel();
        }
        final selectable = tester.renderObject(
          find.byType(SelectableTextSlice).first,
        ) as BookTextSelectable;
        expect(selectable.getSelectedContent()?.plainText, 'Dictionary');
        expect(harness.navigation.leadingPosition, anchor);
        expect(harness.navigation.retainedTextureCount, 0);
        expect(harness.reports, isEmpty);
        expect(harness.taps, 0);

        // Reflow must clear borrowed selection geometry, not advance the logical
        // position or leave handles tied to the replaced measured painter.
        harness.settings.value = harness.settings.value.copyWith(fontSize: 30);
        await tester.pumpAndSettle();
        expect(harness.navigation.leadingPosition, anchor);
        expect(
          (tester.renderObject(
            find.byType(SelectableTextSlice).first,
          ) as BookTextSelectable).getSelectedContent(),
          isNull,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }
  for (final mode in [ReadingMode.pages, ReadingMode.pageFlip]) {
    testWidgets(
      '${mode.name} selection on a continued paragraph reads from its source beginning',
      (tester) async {
        final starts = <text.TextPosition>[];
        final harness = TextViewportHarness(
          store: MemoryDocumentStore(
            sections: [
              text.TextSection(
                id: 's0',
                blocks: [
                  text.TextBlock(
                    id: 'p0',
                    text: 'Dictionary lookup stays local. ' * 40,
                  ),
                ],
              ),
            ],
          ),
        )..onReadFromHere = starts.add;
        harness.settings.value = ReaderSettings(mode: mode);
        await harness.mount(tester);
        harness.navigation.next();
        await tester.pumpAndSettle();
        final anchor = harness.navigation.leadingPosition!;
        expect(anchor.offset, greaterThan(0));
        harness.reports.clear();
        final target = find.byType(BlockSlice).first;
        final slice = tester.widget<BlockSlice>(target);
        final render = tester.renderObject<RenderBox>(target);
        final selectedStart = slice.block.block.text.indexOf(
          'Dictionary',
          slice.start,
        );
        expect(selectedStart, lessThan(slice.end));
        final box = slice.block.painter
            .getBoxesForSelection(
              TextSelection(
                baseOffset: selectedStart,
                extentOffset: selectedStart + 10,
              ),
            )
            .first
            .toRect()
            .shift(render.localToGlobal(Offset(0, -slice.top)));
        final drag = await tester.startGesture(
          Offset(box.left + .1, box.center.dy),
          kind: PointerDeviceKind.mouse,
        );
        var released = false;
        try {
          await drag.moveTo(Offset(box.right + .1, box.center.dy));
          await tester.pump();
          await drag.up();
          released = true;
        } finally {
          if (!released) await drag.cancel();
        }
        await tester.pumpAndSettle();
        await _openSelectionMenu(tester, box.center);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Read from here').first);
        await tester.pumpAndSettle();
        expect(starts, [
          text.TextPosition(
            sectionId: anchor.sectionId,
            blockId: slice.block.block.id,
          ),
        ]);
        expect(harness.navigation.leadingPosition, anchor);
        expect(harness.reports, isEmpty);
        expect(
          (tester.renderObject(
            find.byType(SelectableTextSlice).first,
          ) as BookTextSelectable).getSelectedContent(),
          isNull,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }
  testWidgets(
    'backward cross-paragraph selection reads the first source paragraph even when prose repeats',
    (tester) async {
      final starts = <text.TextPosition>[];
      final harness = TextViewportHarness(
        store: MemoryDocumentStore(
          sections: [
            text.TextSection(
              id: 's0',
              blocks: [
                text.TextBlock(id: 'p0', text: 'Repeated paragraph words.'),
                text.TextBlock(id: 'p1', text: 'Repeated paragraph words.'),
              ],
            ),
          ],
        ),
      )..onReadFromHere = starts.add;
      harness.settings.value = const ReaderSettings(mode: ReadingMode.scroll);
      await harness.mount(tester);
      Offset wordEdge(int index, bool end) {
        final target = find.byType(BlockSlice).at(index);
        final slice = tester.widget<BlockSlice>(target);
        final box = slice.block.painter
            .getBoxesForSelection(
              const TextSelection(baseOffset: 9, extentOffset: 18),
            )
            .single
            .toRect()
            .shift(
              tester
                  .renderObject<RenderBox>(target)
                  .localToGlobal(Offset(0, -slice.top)),
            );
        return Offset(end ? box.right + .1 : box.left + .1, box.center.dy);
      }

      final origin = wordEdge(1, true);
      final end = wordEdge(0, false);
      final drag = await tester.startGesture(
        origin,
        kind: PointerDeviceKind.mouse,
      );
      var released = false;
      try {
        await drag.moveTo(end);
        await tester.pump();
        await drag.up();
        released = true;
      } finally {
        if (!released) await drag.cancel();
      }
      await tester.pumpAndSettle();
      final leaves = find.byType(SelectableTextSlice);
      expect(
        (tester.renderObject(leaves.at(0)) as BookTextSelectable)
            .getSelectedContent()
            ?.plainText,
        'paragraph words.',
      );
      expect(
        (tester.renderObject(leaves.at(1)) as BookTextSelectable)
            .getSelectedContent()
            ?.plainText,
        'Repeated paragraph',
      );
      await _openSelectionMenu(tester, end + const Offset(20, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read from here').first);
      await tester.pumpAndSettle();
      expect(starts, [const text.TextPosition(sectionId: 's0', blockId: 'p0')]);
      expect(harness.reports, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}

Future<void> _openSelectionMenu(WidgetTester tester, Offset point) async {
  final click = await tester.startGesture(
    point,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  var released = false;
  try {
    await click.up();
    released = true;
  } finally {
    if (!released) await click.cancel();
  }
}
