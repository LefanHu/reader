import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/book_service.dart';
import 'package:reader/controller.dart';
import 'package:reader/library.dart';
import 'package:reader/theme.dart';
import 'package:reader/models.dart';

import 'fakes.dart';
import 'support/cloud_identity_fake.dart';

void main() {
  testWidgets(
    'core-only Settings account page restores, cancels, signs in and signs out without changing books',
    (tester) async {
      final identity = FakeCloudIdentity()..email = 'restored@example.test';
      final book = testBook();
      final controller = ReaderController(
        cloudIdentity: identity,
        catalogStore: MemoryCatalogStore([book]),
        settingsStore: MemorySettingsStore(),
        importer: BookImporter(root: Directory.systemTemp),
        picker: FakePicker([]),
        illustrationStore: MemoryIllustrationStore(),
        illustrationApi: FakeIllustrationApi(),
        wordCounter: FakeWordCounter(),
      );
      await controller.initialize();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        await controller.flush();
      });
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
      expect(controller.books.single.lastPosition, book.lastPosition);
      expect(controller.narration, isNull);
      identity.failSignOut = true;
      await expectLater(controller.signOutOfCloud(), throwsStateError);
      await tester.pumpAndSettle();
      expect(controller.cloudEmail, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
