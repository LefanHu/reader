import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/text/text_block.dart' as text;
import 'package:reader/text/text_position.dart' as text;
import 'package:reader/text/text_section.dart' as text;
import 'package:reader/text/viewport.dart';

import 'fixtures/text_documents.dart';
import 'support/memory_document_store.dart';
import 'support/text_viewport_harness.dart';

void main() {
  for (final mode in [ReadingMode.pages, ReadingMode.pageFlip]) {
    testWidgets('${mode.name} restores scrolling on its first visible frame', (
      tester,
    ) async {
      final h = TextViewportHarness();
      await h.mount(tester);
      h.settings.value = h.settings.value.copyWith(mode: mode);
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        h.navigation.next();
        await tester.pumpAndSettle();
      }
      final anchor = h.navigation.leadingPosition!;
      expect(anchor.offset, greaterThan(0));
      h.settings.value = h.settings.value.copyWith(mode: ReadingMode.scroll);
      await tester.pump();
      final scrollable = find.descendant(
        of: find.byType(TextViewport),
        matching: find.byType(Scrollable),
      );
      final paints = find.descendant(
        of: find.byType(TextViewport),
        matching: find.byType(CustomPaint),
      );
      final firstOffset = tester
          .state<ScrollableState>(scrollable)
          .position
          .pixels;
      final firstText = tester.getRect(paints.first);
      expect(firstOffset, greaterThan(0));
      expect(h.navigation.leadingPosition, anchor);
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        firstOffset,
      );
      expect(tester.getRect(paints.first), firstText);
      // An old Scroll pixel offset must not override a newer paginated anchor.
      h.settings.value = h.settings.value.copyWith(mode: mode);
      await tester.pumpAndSettle();
      h.navigation.next();
      await tester.pumpAndSettle();
      final nextAnchor = h.navigation.leadingPosition;
      h.settings.value = h.settings.value.copyWith(mode: ReadingMode.scroll);
      await tester.pump();
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        greaterThan(firstOffset),
      );
      expect(h.navigation.leadingPosition, nextAnchor);
      h.settings.value = h.settings.value.copyWith(mode: mode);
      await tester.pump();
      h.settings.value = h.settings.value.copyWith(mode: ReadingMode.scroll);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, nextAnchor);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('chapter jumps invalidate pending mode restoration reports', (
    tester,
  ) async {
    final h = TextViewportHarness(
      store: MemoryDocumentStore(
        sections: [
          ...multilingualSections(),
          const text.TextSection(
            id: 's1',
            blocks: [text.TextBlock(id: 'p1', text: 'Next chapter')],
          ),
        ],
      ),
    );
    await h.mount(tester);
    h.reports.clear();
    // Run the chapter command ahead of the restoration callback in this frame.
    tester.binding.addPostFrameCallback(
      (_) => h.navigation.goTo(
        const text.TextPosition(sectionId: 's1', blockId: 'p1'),
      ),
    );
    h.settings.value = h.settings.value.copyWith(mode: ReadingMode.scroll);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(h.navigation.leadingPosition!.sectionId, 's1');
    expect(h.reports, isNotEmpty);
    expect(h.reports.every((position) => position.sectionId == 's1'), isTrue);
    expect(tester.takeException(), isNull);
  });
}
