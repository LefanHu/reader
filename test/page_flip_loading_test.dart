import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/text/page_curl.dart';

import 'support/delayed_document_store.dart';
import 'support/page_curl_raster.dart';
import 'support/text_viewport_harness.dart';

void main() {
  testWidgets(
    'chapter loads stay on committed page and stale loads cannot override jumps',
    (tester) async {
      final store = DelayedDocumentStore()..pending = Completer<void>();
      final h = TextViewportHarness(store: store);
      await h.mount(tester);
      final start = h.navigation.leadingPosition;
      h.navigation.next();
      h.navigation.next();
      await tester.pump();
      expect(h.navigation.leadingPosition, start);
      expect(find.bySemanticsLabel('First page'), findsOneWidget);
      h.navigation.goTo(store.sections.last.start);
      await tester.pumpAndSettle();
      store.pending!.complete();
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition!.sectionId, 's2');
      expect(h.navigation.retainedTextureCount, 0);
    },
  );

  testWidgets(
    'drag released during section loading retains its last diagonal raster',
    (tester) async {
      for (final complete in [true, false]) {
        await tester.pumpWidget(const SizedBox.shrink());
        final store = DelayedDocumentStore()..pending = Completer<void>();
        final h = TextViewportHarness(store: store);
        await h.mount(tester);
        final start = h.navigation.leadingPosition;
        final bounds = pageBounds(tester);
        final origin = Offset(
          bounds.left + bounds.width * .75,
          bounds.top + bounds.height * .2,
        );
        final gesture = await tester.startGesture(origin);
        var released = false;
        try {
          await gesture.moveBy(const Offset(-20, 0));
          await tester.pump();
          await gesture.moveTo(
            origin + Offset(-bounds.width * .3, bounds.height * .1),
          );
          await tester.pump();
          await gesture.moveTo(
            origin + Offset(-bounds.width * .5, bounds.height * .15),
          );
          await tester.pump(const Duration(milliseconds: 200));
          if (complete) {
            await gesture.up();
          } else {
            await gesture.cancel();
          }
          released = true;
          expect(h.navigation.leadingPosition, start);
          expect(h.navigation.retainedTextureCount, 0);
          store.pending!.complete();
          await tester.pump();
          await tester.pump();
          final painter = previewPainter(tester);
          final expected = PaperCurlPainter(
            current: painter.current,
            target: painter.target,
            progress: .5,
            grabY: bounds.height * .2,
            fingerY: bounds.height * .35,
            forward: true,
            fromRight: true,
            paper: const Color(0xfffffbf0),
          );
          expect(
            await previewPixels(tester),
            (await tester.runAsync(() => rasterPixels(expected, bounds.size)))!,
          );
          expect(h.navigation.leadingPosition, start);
          expect(h.reports, isEmpty);
          await tester.pumpAndSettle();
          expect(
            h.navigation.leadingPosition!.sectionId,
            complete ? 's1' : 's0',
          );
          expect(h.reports, hasLength(complete ? 1 : 0));
          expect(h.navigation.retainedTextureCount, 0);
        } finally {
          if (!released) await gesture.cancel();
          if (!store.pending!.isCompleted) store.pending!.complete();
          await tester.pumpAndSettle();
        }
      }
    },
  );

  testWidgets('failed adjacent page load offers retry without losing anchor', (
    tester,
  ) async {
    final store = DelayedDocumentStore()..fail = true;
    final h = TextViewportHarness(store: store);
    await h.mount(tester);
    final start = h.navigation.leadingPosition;
    h.navigation.next();
    await tester.pumpAndSettle();
    expect(h.navigation.leadingPosition, start);
    expect(find.text('Could not load page. Retry'), findsOneWidget);
    store.fail = false;
    await tester.tap(find.text('Could not load page. Retry'));
    await tester.pumpAndSettle();
    expect(h.navigation.leadingPosition!.sectionId, 's1');
    expect(h.reports, hasLength(1));
    expect(h.navigation.retainedLayoutCount, lessThanOrEqualTo(2));
  });
}
