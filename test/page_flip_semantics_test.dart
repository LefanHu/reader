import 'package:flutter_test/flutter_test.dart';
import 'package:reader/illustrations/book_text_index.dart';
import 'package:reader/illustrations/chapter_text_index.dart';
import 'package:reader/illustrations/gate.dart';
import 'package:reader/illustrations/indexed_paragraph.dart';
import 'package:reader/illustrations/scene_anchor.dart';
import 'package:reader/text/viewport.dart';

import 'support/delayed_document_store.dart';
import 'support/text_viewport_harness.dart';

void main() {
  testWidgets('illustrations stay locked through previews and cancellations', (
    tester,
  ) async {
    final h = TextViewportHarness(store: DelayedDocumentStore());
    await h.mount(tester);
    final index = BookTextIndex(
      bookHash: 'book',
      chapters: [
        for (var i = 0; i < h.store.sections.length; i++)
          ChapterTextIndex(
            href: 's$i',
            spineOrdinal: i,
            title: null,
            paragraphs: [
              IndexedParagraph(
                id: h.store.sections[i].blocks.first.id,
                text: h.store.sections[i].blocks.first.text,
                cssSelector: '',
                ordinal: 0,
                progression: 0,
              ),
            ],
          ),
      ],
    );
    const anchor = SceneAnchor(
      href: 's0',
      spineOrdinal: 0,
      paragraphId: 'a',
      cssSelector: '',
      fallbackProgression: 0,
    );
    bool unlocked() => const IllustrationGate().hasPassed(
      anchor: anchor,
      index: index,
      position: h.navigation.leadingPosition!,
    );
    expect(unlocked(), false);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TextViewport)),
    );
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-130, 0));
    await tester.pump();
    expect(unlocked(), false);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(unlocked(), false);
    h.navigation.next();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(unlocked(), false);
    await tester.pumpAndSettle();
    expect(unlocked(), true);
  });

  testWidgets('reduced motion retains paragraph semantics and no textures', (
    tester,
  ) async {
    final h = TextViewportHarness(
      store: DelayedDocumentStore(),
      reducedMotion: true,
    );
    final semantics = tester.ensureSemantics();
    await h.mount(tester);
    h.navigation.previous();
    await tester.pumpAndSettle();
    expect(h.reports, isEmpty);
    h.navigation.next();
    await tester.pump();
    expect(h.navigation.leadingPosition!.sectionId, 's1');
    expect(find.bySemanticsLabel('Second page'), findsOneWidget);
    expect(h.navigation.retainedTextureCount, 0);
    h.navigation.previous();
    await tester.pumpAndSettle();
    expect(h.navigation.leadingPosition!.sectionId, 's0');
    semantics.dispose();
  });

  testWidgets(
    'preview semantics exclude future paragraphs and final turn completes without blank page',
    (tester) async {
      final h = TextViewportHarness(store: DelayedDocumentStore());
      final semantics = tester.ensureSemantics();
      await h.mount(tester);
      h.navigation.next();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.bySemanticsLabel('First page'), findsOneWidget);
      expect(find.bySemanticsLabel('Second page'), findsNothing);
      await tester.pumpAndSettle();
      h.navigation.next();
      await tester.pumpAndSettle();
      final lastStart = h.navigation.leadingPosition;
      h.reports.clear();
      h.navigation.next();
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition!.offset, 'Third page'.length);
      expect(h.reports, hasLength(1));
      expect(find.bySemanticsLabel('Third page'), findsOneWidget);
      h.navigation.previous();
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition!.sectionId, 's1');
      expect(h.navigation.leadingPosition, isNot(lastStart));
      expect(h.navigation.retainedLayoutCount, lessThanOrEqualTo(2));
      semantics.dispose();
    },
  );
}
