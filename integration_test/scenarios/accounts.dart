import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test/support/cloud_identity_fake.dart';
import '../support/native_test_app.dart';

/// Real native routes and storage exercise account actions without cloud consent.
/// Provider dialogs are covered separately by signed OAuth validation.
void registerAccountTests() {
  testWidgets(
    'core-only Google account cancellation and sign-out preserve offline books',
    (tester) async {
      final identity = FakeCloudIdentity()..cancel = true;
      final app = await NativeTestApp.launch(tester, cloudIdentity: identity);
      final count = app.controller.catalog.books.length;
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign in with Google'));
      await tester.pumpAndSettle();
      expect(app.controller.cloudEmail, isNull);
      expect(app.controller.narration, isNull);
      identity.cancel = false;
      await tester.tap(find.text('Sign in with Google'));
      await tester.pumpAndSettle();
      expect(app.controller.cloudEmail, 'reader@example.test');
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(app.controller.cloudEmail, isNull);
      expect(app.controller.catalog.books, hasLength(count));
      Navigator.of(tester.element(find.text('Sign in with Google'))).pop();
      await tester.pumpAndSettle();
      await app.openBook('Unicode Test');
      expect(app.textPaints, findsWidgets);
      await app.closeReader();
      await app.capture('google-account-library');
    },
  );
}
