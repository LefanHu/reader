import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/preferences/reader_settings.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/text/block_slice.dart';
import 'package:reader/text/selectable_text_slice.dart';
import 'package:reader/text/text_block.dart' as text;
import 'package:reader/text/text_section.dart' as text;

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
}
