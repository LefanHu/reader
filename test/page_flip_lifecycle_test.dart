import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/text/page_curl.dart';

import 'support/delayed_document_store.dart';
import 'support/text_viewport_harness.dart';

void main() {
  testWidgets(
    'large viewports cap both texture resolutions and release ownership',
    (tester) async {
      tester.view.physicalSize = const Size(3200, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = TextViewportHarness(store: DelayedDocumentStore())
        ..size = const Size(3000, 1000);
      await h.mount(tester);
      h.navigation.next();
      await tester.pump();
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<PaperCurlPainter>()
          .single;
      for (final image in [painter.current, painter.target]) {
        expect(image.width, lessThanOrEqualTo(2048));
        expect(image.height, lessThanOrEqualTo(2048));
        expect(image.height, lessThanOrEqualTo(2000));
      }
      await tester.pumpAndSettle();
      expect(h.navigation.retainedTextureCount, 0);
      h.navigation.next();
      await tester.pumpAndSettle();
      h.navigation.previous();
      await tester.pumpAndSettle();
      expect(h.navigation.retainedLayoutCount, lessThanOrEqualTo(2));
      expect(h.navigation.retainedTextureCount, 0);
    },
  );

  testWidgets(
    'reflow mode changes suspension and disposal discard uncommitted turns',
    (tester) async {
      final h = TextViewportHarness();
      await h.mount(tester);
      final start = h.navigation.leadingPosition;
      h.navigation.next();
      await tester.pump();
      h.settings.value = h.settings.value.copyWith(fontSize: 150);
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, start);
      h.navigation.next();
      await tester.pump();
      h.size = const Size(420, 300);
      await tester.pumpWidget(h.app());
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, start);
      h.navigation.next();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, start);
      expect(h.navigation.retainedTextureCount, 0);
      h.navigation.next();
      await tester.pump();
      h.settings.value = h.settings.value.copyWith(mode: ReadingMode.scroll);
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, start);
      h.settings.value = h.settings.value.copyWith(mode: ReadingMode.pageFlip);
      await tester.pumpAndSettle();
      h.navigation.next();
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(h.navigation.retainedTextureCount, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
