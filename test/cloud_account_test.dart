import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/library/library_screen.dart';
import 'package:reader/theme.dart';
import 'package:reader/preferences/reading_theme.dart';

import 'fixtures/catalog_book.dart';
import 'support/cloud_identity_fake.dart';
import 'support/controller_lifecycle.dart';
import 'support/test_controller.dart';

void main() {
  testWidgets(
    'core-only Settings account page restores, cancels, signs in and signs out without changing books',
    (tester) async {
      final identity = FakeCloudIdentity()..email = 'restored@example.test';
      final book = testBook();
      final controller = await testController(
        books: [book],
        cloudIdentity: identity,
      );
      addControllerTeardown(tester, controller);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildReaderTheme(ReadingTheme.paper),
          home: LibraryScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.cloudEmail, 'restored@example.test');
      expect(identity.signIns, 0);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Account'));
      await tester.pumpAndSettle();
      expect(find.text('restored@example.test'), findsOneWidget);
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(identity.signOuts, 1);
      expect(controller.cloudEmail, isNull);
      identity.cancel = true;
      await tester.tap(find.text('Sign in with Google'));
      await tester.pumpAndSettle();
      expect(controller.cloudEmail, isNull);
      expect(find.byType(SnackBar), findsNothing);
      expect(controller.cloudAccountBusy, false);
      identity.cancel = false;
      await tester.tap(find.text('Sign in with Google'));
      await tester.pumpAndSettle();
      expect(controller.cloudEmail, 'reader@example.test');
      expect(controller.catalog.books.single.lastPosition, book.lastPosition);
      expect(controller.narration, isNull);
      identity.failSignOut = true;
      await expectLater(controller.signOutOfCloud(), throwsStateError);
      await tester.pumpAndSettle();
      expect(controller.cloudEmail, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
