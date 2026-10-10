import 'package:flutter_test/flutter_test.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/text/viewport.dart';

import '../support/native_test_app.dart';

/// Registers frame-level regressions separately for each affected reading mode.
void registerControlTests() {
  for (final mode in ReadingMode.values) {
    testWidgets(
      '${mode.name} controls animate with centered title and stationary text',
      (tester) async {
        final app = await NativeTestApp.launch(tester);
        await app.controller.preferences.configure(mode: mode);
        await app.openBook('Unicode Test');
        await app.advance();
        final anchor = app.viewport.navigation.leadingPosition;
        final viewport = find.byType(TextViewport);
        final bounds = tester.getRect(viewport);
        final text = tester.getRect(app.textPaints.first);
        final title = app.viewport.document.sections.first.title;
        expect(
          tester.getCenter(find.text(title)).dx,
          closeTo(bounds.center.dx, .01),
        );
        await tester.tapAt(bounds.center);
        await tester.pump(const Duration(milliseconds: 80));
        expect(tester.getRect(viewport), bounds);
        expect(tester.getRect(app.textPaints.first), text);
        expect(app.viewport.navigation.leadingPosition, anchor);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Show reading controls'), findsOneWidget);
        expect(tester.getRect(viewport), bounds);
        expect(tester.getRect(app.textPaints.first), text);
        await tester.tap(find.byTooltip('Show reading controls'));
        await tester.pump(const Duration(milliseconds: 80));
        expect(tester.getRect(viewport), bounds);
        expect(tester.getRect(app.textPaints.first), text);
        expect(app.viewport.navigation.leadingPosition, anchor);
        await tester.pumpAndSettle();
        expect(tester.getRect(viewport), bounds);
        expect(tester.getRect(app.textPaints.first), text);
        expect(app.viewport.navigation.leadingPosition, anchor);
      },
    );
  }

  for (final mode in [ReadingMode.pages, ReadingMode.pageFlip]) {
    testWidgets(
      '${mode.name} restores Scroll on its first visible frame and returns without drift',
      (tester) async {
        final app = await NativeTestApp.launch(tester);
        await app.controller.preferences.configure(mode: mode);
        await app.openBook('Unicode Test');
        await app.advance();
        final anchor = app.viewport.navigation.leadingPosition;
        await app.controller.preferences.configure(mode: ReadingMode.scroll);
        await tester.pump();
        final text = tester.getRect(app.textPaints.first);
        await tester.pumpAndSettle();
        expect(tester.getRect(app.textPaints.first), text);
        expect(app.viewport.navigation.leadingPosition, anchor);
        await app.controller.preferences.configure(mode: mode);
        await tester.pump();
        final pageText = tester.getRect(app.textPaints.first);
        await tester.pumpAndSettle();
        expect(tester.getRect(app.textPaints.first), pageText);
        expect(app.viewport.navigation.leadingPosition, anchor);
      },
    );
  }
}
