import 'package:flutter_test/flutter_test.dart';
import 'package:reader/models.dart';
import 'package:reader/text/viewport.dart';

import '../support/native_test_app.dart';

/// Registers interactive texture ownership and cancellation on native canvases.
void registerPageFlipTests() {
  testWidgets(
    'cancelled curl releases preview textures and preserves the committed anchor',
    (tester) async {
      final app = await NativeTestApp.launch(tester);
      await app.controller.configure(
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
}
