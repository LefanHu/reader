import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/text/reader_navigation.dart';
import 'package:reader/text/text_position.dart' as text;

import 'support/text_viewport_harness.dart';

void main() {
  testWidgets(
    'replacing navigation detaches old commands and restores complete anchors',
    (tester) async {
      final harness = TextViewportHarness();
      await harness.mount(tester);
      final original = harness.navigation;
      final start = original.leadingPosition!;
      original.next();
      await tester.pumpAndSettle();
      final next = original.leadingPosition!;
      expect(next, isNot(start));
      expect(harness.reports, <text.TextPosition>[next]);

      // Logical restoration needs frames before its completion can be awaited.
      final reset = original.restore(start);
      await tester.pumpAndSettle();
      await reset;
      expect(original.leadingPosition, start);
      harness.reports.clear();

      final replacement = TextReaderNavigation();
      await tester.pumpWidget(harness.app(navigation: replacement));
      await tester.pumpAndSettle();
      expect(replacement.leadingPosition, start);
      expect(harness.reports, isEmpty);

      original.next();
      original.goTo(next);
      final detachedRestore = original.restore(next);
      await tester.pumpAndSettle();
      await detachedRestore;
      expect(replacement.leadingPosition, start);
      expect(harness.reports, isEmpty);
      expect(original.leadingPosition, isNull);
      expect(original.retainedLayoutCount, 0);
      expect(original.retainedTextureCount, 0);

      replacement.next();
      await tester.pumpAndSettle();
      expect(replacement.leadingPosition, next);
      expect(harness.reports, <text.TextPosition>[next]);
      final restore = replacement.restore(start);
      await tester.pumpAndSettle();
      await restore;
      expect(replacement.leadingPosition, start);
      expect(harness.reports, <text.TextPosition>[next]);

      await tester.pumpWidget(const SizedBox.shrink());
      for (final navigation in [original, replacement]) {
        expect(navigation.leadingPosition, isNull);
        expect(navigation.retainedLayoutCount, 0);
        expect(navigation.retainedTextureCount, 0);
        navigation.next();
        navigation.goTo(next);
        final detached = navigation.restore(next);
        await tester.pump();
        await detached;
        expect(navigation.leadingPosition, isNull);
      }
      expect(harness.reports, <text.TextPosition>[next]);
    },
  );
}
