import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/narration/native_narration_player.dart';
import 'package:reader/narration/session.dart';
import 'package:reader/text/viewport.dart';

import '../../test/fixtures/narration_audio.dart';
import '../../test/support/fake_narration_api.dart';
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
      // Route transitions must not consume the whole fixture before media actions.
      api.gate = Completer<Uint8List>()..complete(testWav(samples: 24000 * 60));
      await app.openBook('Unicode Test');
      await tester.tap(find.byTooltip('Listen'));
      await tester.pumpAndSettle();
      expect(find.text('Listen with AI narration?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.registrations, 0);
      expect(api.requests, isEmpty);
      await app.runWithFrames(() => app.controller.consentToNarration(book));
      final initial = app.controller.catalog.books
          .firstWhere((item) => item.hash == book.hash)
          .lastPosition;
      await app.runWithFrames(session.play);
      await tester.pump();
      expect(session.status, NarrationStatus.playing);
      // Leaving the reader flushes offsets but keeps the app-lifetime native handler.
      await app.closeReader();
      expect(session.ownsPosition(book), isTrue);
      expect(find.byTooltip('Pause narration'), findsOneWidget);
      final native = session.player as NativeNarrationPlayer;
      await app.runWithFrames(native.pause);
      await tester.pumpAndSettle();
      expect(session.status, NarrationStatus.paused);
      api.offline = true;
      await app.runWithFrames(native.play);
      await tester.pump();
      expect(session.status, NarrationStatus.playing);
      await app.runWithFrames(() => native.seek(const Duration(seconds: 59)));
      await app.runWithFrames(native.fastForward);
      await app.runWithFrames(
        () => Future<void>.delayed(const Duration(milliseconds: 1200)),
      );
      await tester.pump();
      expect(
        app.controller.catalog.books
            .firstWhere((item) => item.hash == book.hash)
            .lastPosition,
        initial,
      );
      await app.runWithFrames(native.pause);
      await app.runWithFrames(
        () => app.controller.preferences.configure(narrationSpeed: 1.5),
      );
      expect(session.manifest.speed, 1.5);
      api.offline = false;
      await app.openBook('Unicode Test');
      await app.runWithFrames(session.play);
      await tester.pump();
      tester.widget<TextViewport>(find.byType(TextViewport)).navigation.next();
      await tester.pumpAndSettle();
      expect(session.ownsPosition(book), isFalse);
      expect(session.manifest.chunkId, isNull);
      await app.runWithFrames(
        () => app.controller.preferences.configure(narrationVoice: 'cedar'),
      );
      await app.runWithFrames(session.play);
      await tester.pump();
      expect(api.voices.last, 'cedar');
      await app.capture('narration-reader');
      await app.closeReader();
      await app.runWithFrames(() => app.controller.delete(book));
      await tester.pumpAndSettle();
      expect(session.book, isNull);
      expect(await File(book.path).exists(), isFalse);
      expect(find.byTooltip('Play narration'), findsNothing);
      await app.runWithFrames(app.controller.signOutOfCloud);
      expect(api.signOuts, 1);
      await app.runWithFrames(app.controller.deleteCloudAccount);
      expect(api.accountDeletions, 1);
      expect(app.controller.catalog.books, hasLength(1));
    },
  );
}
