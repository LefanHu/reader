import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/text/viewport.dart';

import 'fixtures/text_documents.dart';
import 'support/memory_document_store.dart';
import 'support/page_curl_raster.dart';
import 'support/text_viewport_harness.dart';

void main() {
  for (final rtl in [false, true]) {
    for (final forward in [true, false]) {
      testWidgets(
        '${rtl ? 'RTL' : 'LTR'} ${forward ? 'forward' : 'backward'} curls follow grab height and live pointer without committing previews',
        (tester) async {
          final h = TextViewportHarness(
            store: rtl ? MemoryDocumentStore(sections: rtlSections()) : null,
          );
          await h.mount(tester);
          if (!forward) {
            h.navigation.next();
            await tester.pumpAndSettle();
          }
          final start = h.navigation.leadingPosition;
          if (forward) {
            h.navigation.next();
          } else {
            h.navigation.previous();
          }
          await tester.pumpAndSettle();
          final expected = h.navigation.leadingPosition;
          expect(expected, isNot(start));
          if (forward) {
            h.navigation.previous();
          } else {
            h.navigation.next();
          }
          await tester.pumpAndSettle();
          expect(h.navigation.leadingPosition, start);
          h.reports.clear();

          final bounds = pageBounds(tester);
          final sign = forward == rtl ? 1.0 : -1.0;
          final previews = <Uint8List>[];
          final verticalGesture = await tester.startGesture(bounds.center);
          var verticalReleased = false;
          try {
            await verticalGesture.moveBy(Offset(0, bounds.height * .2));
            await tester.pump();
            expect(h.navigation.leadingPosition, start);
            expect(h.navigation.retainedTextureCount, 0);
            expect(h.reports, isEmpty);
            await verticalGesture.cancel();
            verticalReleased = true;
            await tester.pumpAndSettle();
          } finally {
            if (!verticalReleased) await verticalGesture.cancel();
            await tester.pumpAndSettle();
          }

          for (final height in [.2, .5, .8]) {
            final origin = Offset(
              bounds.center.dx,
              bounds.top + bounds.height * height,
            );
            final heldPosition = origin + Offset(sign * bounds.width * .25, 0);
            final gesture = await tester.startGesture(origin);
            var released = false;
            try {
              await gesture.moveBy(Offset(sign * 20, 0));
              await tester.pump();
              await gesture.moveTo(heldPosition);
              await tester.pump();
              final held = await previewPixels(tester);
              previews.add(held);
              final progress = previewPainter(tester).progress;
              expect(progress, closeTo(.25, .000001));
              expect(h.navigation.retainedTextureCount, 2);

              // Full localPosition remains two-dimensional after horizontal
              // recognition; a vertical update changes only the rendered bend.
              await gesture.moveTo(
                heldPosition + Offset(0, bounds.height * .1),
              );
              await tester.pump();
              expect(await previewPixels(tester), isNot(held));
              expect(previewPainter(tester).progress, progress);
              expect(h.navigation.leadingPosition, start);
              expect(h.reports, isEmpty);
              await gesture.moveTo(heldPosition);
              await tester.pump();
              expect(await previewPixels(tester), held);

              // Crossing the grab clamps progress at zero, but returning to
              // the same pointer restores the same preview, not accumulated
              // clamped deltas or a newly selected logical direction.
              await gesture.moveTo(
                origin + Offset(-sign * bounds.width * .05, 0),
              );
              await tester.pump();
              expect(previewPainter(tester).progress, 0);
              await gesture.moveTo(heldPosition);
              await tester.pump();
              expect(await previewPixels(tester), held);
              expect(previewPainter(tester).progress, progress);
              expect(h.navigation.leadingPosition, start);
              expect(h.reports, isEmpty);
              await gesture.cancel();
              released = true;
              await tester.pumpAndSettle();
              expect(h.navigation.leadingPosition, start);
              expect(h.reports, isEmpty);
              expect(h.navigation.retainedTextureCount, 0);
              expect(h.navigation.retainedLayoutCount, lessThanOrEqualTo(2));
            } finally {
              if (!released) await gesture.cancel();
              await tester.pumpAndSettle();
            }
          }
          expect(previews[0], isNot(previews[1]));
          expect(previews[1], isNot(previews[2]));
          expect(previews[0], isNot(previews[2]));

          final origin = Offset(
            bounds.center.dx,
            bounds.top + bounds.height * .2,
          );
          final gesture = await tester.startGesture(origin);
          var released = false;
          try {
            await gesture.moveBy(Offset(sign * 20, 0));
            await tester.pump();
            await gesture.moveTo(
              origin + Offset(sign * bounds.width * .5, bounds.height * .1),
            );
            await tester.pump(const Duration(milliseconds: 200));
            expect(h.navigation.leadingPosition, start);
            expect(h.reports, isEmpty);
            expect(h.navigation.retainedTextureCount, 2);
            await gesture.up();
            released = true;
            await tester.pumpAndSettle();
            expect(h.navigation.leadingPosition, expected);
            expect(h.reports, [expected]);
            expect(h.navigation.retainedTextureCount, 0);
          } finally {
            if (!released) await gesture.cancel();
            await tester.pumpAndSettle();
          }
        },
      );
    }
  }

  testWidgets(
    'cancelled drag preserves anchor and completed drag advances after release',
    (tester) async {
      final h = TextViewportHarness();
      await h.mount(tester);
      final start = h.navigation.leadingPosition;
      final center = tester.getCenter(find.byType(TextViewport));
      var gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump(const Duration(milliseconds: 200));
      expect(h.navigation.leadingPosition, start);
      expect(h.navigation.retainedTextureCount, 2);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, start);
      expect(h.reports, isEmpty);
      expect(h.navigation.retainedTextureCount, 0);
      gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-150, 0));
      await tester.pump(const Duration(milliseconds: 200));
      expect(h.navigation.leadingPosition, start);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, isNot(start));
      expect(h.reports, hasLength(1));
      expect(h.taps, 0);
    },
  );

  testWidgets('release and cancel settle from the exact last diagonal shape', (
    tester,
  ) async {
    for (final complete in [false, true]) {
      await tester.pumpWidget(const SizedBox.shrink());
      final h = TextViewportHarness();
      await h.mount(tester);
      final start = h.navigation.leadingPosition;
      final bounds = tester.getRect(find.byType(TextViewport)).deflate(20);
      final origin = Offset(bounds.center.dx, bounds.top + bounds.height * .2);
      final gesture = await tester.startGesture(origin);
      var released = false;
      try {
        await gesture.moveBy(const Offset(-20, 0));
        await tester.pump();
        await gesture.moveTo(origin + Offset(-h.size.width * .4, 35));
        await tester.pump(const Duration(milliseconds: 200));
        final held = await previewPixels(tester);
        if (complete) {
          await gesture.up();
        } else {
          await gesture.cancel();
        }
        released = true;
        await tester.pump();
        expect(await previewPixels(tester), held);
        expect(h.navigation.leadingPosition, start);
        expect(h.reports, isEmpty);
        await tester.pump(const Duration(milliseconds: 30));
        expect(await previewPixels(tester), isNot(held));
        await tester.pumpAndSettle();
        expect(h.navigation.leadingPosition, complete ? isNot(start) : start);
        expect(h.reports, hasLength(complete ? 1 : 0));
        expect(h.navigation.retainedTextureCount, 0);
      } finally {
        if (!released) await gesture.cancel();
        await tester.pumpAndSettle();
      }
    }
  });

  testWidgets('fast short flick completes and reversed release cancels', (
    tester,
  ) async {
    final h = TextViewportHarness();
    await h.mount(tester);
    final start = h.navigation.leadingPosition;
    await tester.fling(find.byType(TextViewport), const Offset(-95, 0), 1000);
    await tester.pumpAndSettle();
    expect(h.navigation.leadingPosition, isNot(start));
    h.navigation.previous();
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TextViewport)),
    );
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveBy(
      const Offset(20, 0),
      timeStamp: const Duration(milliseconds: 310),
    );
    await gesture.up(timeStamp: const Duration(milliseconds: 311));
    await tester.pumpAndSettle();
    expect(h.navigation.leadingPosition, start);
  });
}
