import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/narration/player.dart';
import 'package:reader/narration/session.dart';
import 'package:reader/text/viewport.dart';

import '../../test/support/narration_fakes.dart';
import '../support/native_test_app.dart';

/// Real importing, audio decoding, persistence and reader routes with offline cloud input.
void registerNarrationTests() {
  testWidgets(
    'consent, native media controls, offline replay and deletion preserve reading progress',
    (tester) async {
      final app = await NativeTestApp.launch(tester, narration: true);
      final book = app.book('Unicode Test');
      final session = app.controller.narration!;
      final api = session.api as FakeNarrationApi;
      await app.openBook('Unicode Test');
      await tester.tap(find.byTooltip('Listen'));
      await tester.pumpAndSettle();
      expect(find.text('Listen with AI narration?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.registrations, 0);
      expect(api.requests, isEmpty);
      await tester.runAsync(() => app.controller.consentToNarration(book));
      final initial = app.controller.books
          .firstWhere((item) => item.hash == book.hash)
          .lastPosition;
      await tester.runAsync(session.play);
      await tester.pump();
      expect(session.status, NarrationStatus.playing);
      // Leaving the reader flushes offsets but keeps the app-lifetime native handler.
      await app.closeReader();
      expect(session.ownsPosition(book), isTrue);
      expect(find.byTooltip('Pause narration'), findsOneWidget);
      final native = session.player as NativeNarrationPlayer;
      await tester.runAsync(native.pause);
      await tester.pumpAndSettle();
      expect(session.status, NarrationStatus.paused);
      api.offline = true;
      await tester.runAsync(native.play);
      await tester.pump();
      expect(session.status, NarrationStatus.playing);
      await tester.runAsync(native.fastForward);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1200)),
      );
      await tester.pump();
      expect(
        app.controller.books
            .firstWhere((item) => item.hash == book.hash)
            .lastPosition,
        initial,
      );
      await tester.runAsync(native.pause);
      await tester.runAsync(() => session.configure(speed: 1.5));
      expect(session.manifest.speed, 1.5);
      api.offline = false;
      await app.openBook('Unicode Test');
      await tester.runAsync(session.play);
      await tester.pump();
      tester.widget<TextViewport>(find.byType(TextViewport)).navigation.next();
      await tester.pumpAndSettle();
      expect(session.ownsPosition(book), isFalse);
      expect(session.manifest.chunkId, isNull);
      await tester.runAsync(() => session.configure(voice: 'cedar'));
      await tester.runAsync(session.play);
      await tester.pump();
      expect(api.voices.last, 'cedar');
      await app.capture('narration-reader');
      await app.closeReader();
      await tester.runAsync(() => app.controller.delete(book));
      await tester.pumpAndSettle();
      expect(session.book, isNull);
      expect(await File(book.path).exists(), isFalse);
      expect(find.byTooltip('Play narration'), findsNothing);
      await tester.runAsync(app.controller.signOutOfIllustrations);
      expect(api.signOuts, 1);
      await tester.runAsync(app.controller.deleteIllustrationAccount);
      expect(api.accountDeletions, 1);
      expect(app.controller.books, hasLength(1));
    },
  );
}
