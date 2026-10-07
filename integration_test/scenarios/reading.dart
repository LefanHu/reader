import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/models.dart';
import 'package:reader/text/document.dart';
import 'package:reader/text/viewport.dart';
import 'package:reader/theme.dart';

import '../support/native_test_app.dart';

/// Registers reading positions, reflow, contents navigation, and live palettes.
void registerReadingTests() {
  testWidgets(
    'retains a Unicode anchor through typography reflow exit resume and keyboard navigation',
    (tester) async {
      final app = await NativeTestApp.launch(tester);
      await app.openBook('Unicode Test');
      await app.advance();
      final anchor = app.viewport.navigation.leadingPosition!;
      expect(anchor.blockId, isNot(''));
      final book = app.book('Unicode Test');
      final section = await TextDocumentStore().loadSection(
        book.path,
        anchor.sectionId,
      );
      final block = section.blocks.firstWhere(
        (block) => block.id == anchor.blockId,
      );
      expect(graphemeFloor(block.text, anchor.offset), anchor.offset);
      await app.controller.configure(
        mode: ReadingMode.pageFlip,
        fontSize: 140,
        serif: false,
        theme: ReadingTheme.sepia,
      );
      await tester.pumpAndSettle();
      expect(app.viewport.navigation.leadingPosition, anchor);
      await app.closeReader();
      expect(
        (await app.store.load())
            .firstWhere((b) => b.hash == book.hash)
            .lastPosition,
        anchor,
      );
      await tester.tap(find.text('Continue reading'));
      await tester.pumpAndSettle();
      expect(app.viewport.navigation.leadingPosition, anchor);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(app.viewport.navigation.leadingPosition, isNot(anchor));
    },
  );

  testWidgets('nested EPUB contents navigate to the requested paragraph', (
    tester,
  ) async {
    final app = await NativeTestApp.launch(tester);
    await app.openBook('Novel');
    final expected =
        app.viewport.document.contents.single.children.single.position!;
    await tester.tap(find.byTooltip('Choose chapter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Passage'));
    await tester.pumpAndSettle();
    expect(app.viewport.navigation.leadingPosition, expected);
    final paragraphs = tester.widgetList<Semantics>(
      find.descendant(
        of: find.byType(TextViewport),
        matching: find.byType(Semantics),
      ),
    );
    expect(
      paragraphs.any(
        (paragraph) => paragraph.properties.label == 'مرحبا بالعالم\n第二行',
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  for (final preset in ReadingTheme.values) {
    testWidgets(
      'settings apply ${preset.name} to the reader and open panel without moving text',
      (tester) async {
        final app = await NativeTestApp.launch(tester);
        // Paper must also be an actual theme transition, not the default state.
        if (preset == ReadingTheme.paper) {
          await app.controller.configure(theme: ReadingTheme.dark);
          await tester.pumpAndSettle();
        }
        await app.openBook('Unicode Test');
        await app.advance();
        final anchor = app.viewport.navigation.leadingPosition;
        final bounds = tester.getRect(find.byType(TextViewport));
        await tester.tap(find.byTooltip('Reading settings'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(themeLabel(preset)));
        await tester.tap(find.text(themeLabel(preset)));
        await tester.pumpAndSettle();
        final expected = buildReaderTheme(preset).colorScheme;
        expect(app.viewport.background, expected.surface);
        expect(app.viewport.foreground, expected.onSurface);
        expect(
          Theme.of(tester.element(find.byTooltip('Close settings')))
              .colorScheme,
          expected,
        );
        expect(app.viewport.navigation.leadingPosition, anchor);
        expect(tester.getRect(find.byType(TextViewport)), bounds);
        await tester.tap(find.byTooltip('Close settings'));
        await tester.pumpAndSettle();
        await app.closeReader();
        expect(
          Theme.of(tester.element(find.text('Your library'))).colorScheme,
          expected,
        );
      },
    );
  }
}
