import 'package:flutter_test/flutter_test.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/preferences/reading_theme.dart';
import 'package:reader/text/viewport.dart';

import '../support/native_test_app.dart';

/// Registers interactive texture ownership and cancellation on native canvases.
void registerPageFlipTests() {
  testWidgets(
    'cancelled curl releases preview textures and preserves the committed anchor',
    (tester) async {
      final app = await NativeTestApp.launch(tester);
      await app.controller.preferences.configure(
        mode: ReadingMode.pageFlip,
        fontSize: 140,
        serif: false,
        theme: ReadingTheme.dark,
      );
      await app.openBook('Unicode Test');
      await app.advance();
      final anchor = app.viewport.navigation.leadingPosition;
      final bounds = tester.getRect(find.byType(TextViewport));
      final drag = await tester.startGesture(bounds.center);
      try {
        await drag.moveBy(const Offset(-20, 0));
        await tester.pump();
        await drag.moveBy(Offset(-bounds.width * .28, 0));
        await tester.pump(const Duration(milliseconds: 200));
        expect(app.viewport.navigation.leadingPosition, anchor);
        expect(app.viewport.navigation.retainedTextureCount, 2);
        await app.capture('curl');
      } finally {
        // Release the native pointer even when a preview assertion fails.
        await drag.cancel();
        await tester.pumpAndSettle();
      }
      expect(app.viewport.navigation.leadingPosition, anchor);
      expect(app.viewport.navigation.retainedTextureCount, 0);
    },
  );

  testWidgets(
    'page curls follow grab height and diagonal motion before committing',
    (tester) async {
      final app = await NativeTestApp.launch(tester);
      await app.runWithFrames(
        () => app.controller.preferences.configure(
          mode: ReadingMode.pageFlip,
          fontSize: 140,
          serif: false,
          theme: ReadingTheme.paper,
        ),
      );
      await app.openBook('Unicode Test');
      final book = app.book('Unicode Test');
      final navigation = app.viewport.navigation;
      await app.advance();
      final anchorA = navigation.leadingPosition!;
      await app.advance();
      final anchorB = navigation.leadingPosition!;
      expect(anchorB, isNot(anchorA));
      navigation.previous();
      await tester.pumpAndSettle();
      expect(navigation.leadingPosition, anchorA);

      for (final upper in [true, false]) {
        final bounds = tester.getRect(find.byType(TextViewport));
        final width = bounds.width - 40;
        final height = bounds.height - 24;
        final grab =
            bounds.topLeft +
            Offset(20 + width * .75, 12 + height * (upper ? .2 : .8));
        final name = upper ? 'curl-upper' : 'curl-lower';
        final drag = await tester.startGesture(grab);
        try {
          // Claim horizontally, then reach exactly .25W from the down position.
          await drag.moveBy(const Offset(-20, 0));
          await tester.pump();
          await drag.moveBy(Offset(20 - width * .25, 0));
          await tester.pumpAndSettle();
          expect(navigation.leadingPosition, anchorA);
          expect(navigation.retainedTextureCount, 2);
          await app.capture(name);
          await drag.moveBy(Offset(0, height * .1));
          await tester.pump();
          expect(navigation.leadingPosition, anchorA);
          expect(navigation.retainedTextureCount, 2);
          await app.capture('$name-diagonal');
        } finally {
          await drag.cancel();
          await tester.pumpAndSettle();
        }
        expect(navigation.leadingPosition, anchorA);
        expect(navigation.retainedTextureCount, 0);
        expect(navigation.retainedLayoutCount, lessThanOrEqualTo(2));
      }

      for (final forward in [true, false]) {
        // Reopening mounts a new viewport, so obtain its current navigation.
        final currentNavigation = app.viewport.navigation;
        final before = forward ? anchorA : anchorB;
        final expected = forward ? anchorB : anchorA;
        final bounds = tester.getRect(find.byType(TextViewport));
        final width = bounds.width - 40;
        final height = bounds.height - 24;
        final direction = forward ? -1.0 : 1.0;
        final grab =
            bounds.topLeft +
            Offset(
              20 + width * (forward ? .75 : .25),
              12 + height * (forward ? .2 : .8),
            );
        final drag = await tester.startGesture(grab);
        var released = false;
        try {
          await drag.moveBy(Offset(direction * 20, 0));
          await tester.pump();
          await drag.moveBy(
            Offset(direction * (width * .5 - 20), -direction * height * .1),
          );
          await tester.pumpAndSettle();
          // A deliberate hold makes completion depend on distance, not a flick.
          await tester.pump(const Duration(milliseconds: 200));
          expect(currentNavigation.leadingPosition, before);
          expect(currentNavigation.retainedTextureCount, 2);
          await drag.up();
          released = true;
          await tester.pumpAndSettle();
        } finally {
          if (!released) await drag.cancel();
          await tester.pumpAndSettle();
        }
        expect(currentNavigation.leadingPosition, expected);
        expect(currentNavigation.retainedTextureCount, 0);
        expect(currentNavigation.retainedLayoutCount, lessThanOrEqualTo(2));
        await app.closeReader();
        expect(
          (await app.store.load())
              .firstWhere((item) => item.hash == book.hash)
              .lastPosition,
          expected,
        );
        await app.openBook('Unicode Test');
        final reopenedNavigation = app.viewport.navigation;
        await tester.pumpAndSettle();
        expect(reopenedNavigation.leadingPosition, expected);
      }
    },
  );
}
