import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/text/block_slice.dart';
import 'package:reader/text/dictionary_lookup.dart';

import '../../test/fixtures/selection_book.dart';
import '../support/native_test_app.dart';

/// Each mode imports a fresh real document and verifies platform clipboard and
/// dictionary behavior without screenshot capture or manual visual inspection.
void registerSelectionTests() {
  for (final mode in ReadingMode.values) {
    testWidgets('Text selection and dictionary lookup ${mode.name}', (
      tester,
    ) async {
      final app = await NativeTestApp.launch(
        tester,
        textBytes: selectionBookFixture(),
      );
      await app.runWithFrames(
        () => app.controller.preferences.configure(mode: mode, fontSize: 24),
      );
      await app.openBook('Unicode Test');
      final anchor = app.viewport.navigation.leadingPosition!;
      final saved = app.book('Unicode Test').lastPosition;
      final first = find
          .byWidgetPredicate(
            (widget) =>
                widget is BlockSlice &&
                widget.block.block.text == selectionOpening,
          )
          .first;
      final block = tester.widget<BlockSlice>(first);
      final render = tester.renderObject<RenderBox>(first);
      final word = _sourceRect(block, render, 0, 10);
      final passage = _sourceRect(block, render, 0, 17);
      final region = tester.state<SelectableRegionState>(
        find.byType(SelectableRegion),
      );

      await _selectWord(tester, word);
      await _copy(tester);
      expect(
        (await tester.runAsync(() => Clipboard.getData(Clipboard.kTextPlain)))
            ?.text,
        'Dictionary',
      );
      expect(app.viewport.navigation.leadingPosition, anchor);
      expect(app.book('Unicode Test').lastPosition, saved);

      if (Platform.isMacOS) {
        await _mouseDrag(tester, passage);
        await _contextMenu(tester, passage.center);
      } else {
        // Move the real end handle, using the native control's public geometry
        // rather than dispatching a synthetic selection event to a renderer.
        await _extendTouchHandle(tester, region, word, passage);
      }
      await _copy(tester);
      expect(
        (await tester.runAsync(() => Clipboard.getData(Clipboard.kTextPlain)))
            ?.text,
        'Dictionary lookup',
      );
      expect(app.viewport.navigation.leadingPosition, anchor);
      expect(app.book('Unicode Test').lastPosition, saved);

      region.clearSelection();
      await tester.pumpAndSettle();
      await _selectWord(tester, word);
      await tester.tap(find.text('Look Up').first);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.pump();
      expect(
        find.textContaining('Could not open the dictionary'),
        findsNothing,
      );
      expect(app.viewport.navigation.leadingPosition, anchor);
      expect(app.book('Unicode Test').lastPosition, saved);
      expect(app.viewport.navigation.retainedTextureCount, 0);
      expect(app.viewport.navigation.retainedLayoutCount, lessThanOrEqualTo(2));
      // UIKit modal cleanup is the same owned-presentation lifecycle used when
      // reader selection is cleared; AppKit dismisses its nonmodal overlay itself.
      await tester.runAsync(dismissDictionary);
      await tester.pumpAndSettle();
      expect(app.viewport.navigation.leadingPosition, anchor);
      expect(app.book('Unicode Test').lastPosition, saved);
      await app.closeReader();
      expect(
        (await app.store.load())
            .firstWhere((book) => book.title == 'Unicode Test')
            .lastPosition,
        anchor,
      );
    });
  }
}

Rect _sourceRect(BlockSlice slice, RenderBox render, int start, int end) {
  final boxes = slice.block.painter.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: end),
  );
  var local = boxes.first.toRect();
  for (final box in boxes.skip(1)) {
    local = local.expandToInclude(box.toRect());
  }
  return local.shift(render.localToGlobal(Offset(0, -slice.top)));
}

Future<void> _selectWord(WidgetTester tester, Rect word) async {
  if (Platform.isMacOS) {
    await _mouseDrag(tester, word);
    await _contextMenu(tester, word.center);
  } else {
    await tester.longPressAt(word.center);
    await tester.pumpAndSettle();
  }
}

Future<void> _mouseDrag(WidgetTester tester, Rect text) async {
  final drag = await tester.startGesture(
    Offset(text.left + .1, text.center.dy),
    kind: PointerDeviceKind.mouse,
  );
  var released = false;
  try {
    await drag.moveTo(Offset(text.right + .1, text.center.dy));
    await tester.pump();
    await drag.up();
    released = true;
    await tester.pumpAndSettle();
  } finally {
    if (!released) await drag.cancel();
  }
}

Future<void> _contextMenu(WidgetTester tester, Offset point) async {
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
  await tester.pumpAndSettle();
}

Future<void> _copy(WidgetTester tester) async {
  await tester.tap(find.text('Copy').first);
  await tester.pumpAndSettle();
}

Future<void> _extendTouchHandle(
  WidgetTester tester,
  SelectableRegionState region,
  Rect word,
  Rect passage,
) async {
  final overlay = region.selectionOverlay!;
  final controls = overlay.selectionControls!;
  final height = overlay.lineHeightAtEnd;
  final size = controls.getHandleSize(height);
  final handleAnchor = controls.getHandleAnchor(overlay.endHandleType, height);
  final render = region.context.findRenderObject()! as RenderBox;
  final end = render.localToGlobal(region.selectionEndpoints.last.point);
  final center = end - handleAnchor + Offset(size.width / 2, size.height / 2);
  final drag = await tester.startGesture(center);
  var released = false;
  try {
    await drag.moveBy(Offset(passage.right - word.right, 0));
    await tester.pump();
    await drag.up();
    released = true;
    await tester.pumpAndSettle();
  } finally {
    if (!released) await drag.cancel();
  }
}
