import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/text/grapheme_boundary.dart' as text;
import 'package:reader/text/viewport.dart';

import 'fixtures/text_documents.dart';
import 'support/memory_document_store.dart';
import 'support/text_viewport_harness.dart';

void main() {
  testWidgets(
    'page flip commits the same measured anchor as immediate pages once',
    (tester) async {
      final h = TextViewportHarness();
      await h.mount(tester);
      final start = h.navigation.leadingPosition;
      h.settings.value = h.settings.value.copyWith(mode: ReadingMode.pages);
      await tester.pumpAndSettle();
      h.navigation.next();
      await tester.pumpAndSettle();
      final expected = h.navigation.leadingPosition;
      h.navigation.previous();
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, start);
      h.settings.value = h.settings.value.copyWith(mode: ReadingMode.pageFlip);
      await tester.pumpAndSettle();
      h.reports.clear();
      h.navigation.next();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));
      expect(h.navigation.leadingPosition, start);
      expect(h.reports, isEmpty);
      expect(h.navigation.retainedTextureCount, 2);
      h.navigation.next(); // Requests during settling do not queue extra turns.
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, expected);
      expect(h.reports, [expected]);
      expect(h.navigation.retainedTextureCount, 0);
      expect(
        text.graphemeFloor(
          h.store.sections.first.blocks.first.text,
          expected!.offset,
        ),
        expected.offset,
      );
    },
  );

  testWidgets(
    'edge taps and RTL keys turn logically while center toggles controls',
    (tester) async {
      final h = TextViewportHarness(
        store: MemoryDocumentStore(sections: rtlSections()),
      );
      await h.mount(tester);
      final rect = tester.getRect(find.byType(TextViewport));
      final start = h.navigation.leadingPosition;
      await tester.tapAt(rect.center);
      expect(h.taps, 1);
      await tester.tapAt(Offset(rect.left + 30, rect.center.dy));
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, isNot(start));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, start);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, isNot(start));
      await tester.tapAt(Offset(rect.right - 30, rect.center.dy));
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, start);
    },
  );
}
