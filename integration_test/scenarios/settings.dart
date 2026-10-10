import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/narration/native_narration_player.dart';
import 'package:reader/narration/session.dart';
import 'package:reader/preferences/reader_settings.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/preferences/reading_theme.dart';

import '../../test/fixtures/narration_audio.dart';
import '../../test/support/fake_narration_api.dart';
import '../support/native_test_app.dart';

// Resolve lazy children only after scrolling; compact iOS and wide macOS have
// different category/detail scrollables and different Back-button semantics.
class _SettingsFlow {
  _SettingsFlow(this.tester);
  final WidgetTester tester;
  bool get wide => find.byType(VerticalDivider).evaluate().isNotEmpty;

  Future<void> visible(Finder target, {bool categories = false}) async {
    final scrollable = tester.state<ScrollableState>(
      categories ? find.byType(Scrollable).first : find.byType(Scrollable).last,
    );
    scrollable.position.jumpTo(0);
    await tester.pump();
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        target,
        180,
        scrollable: categories
            ? find.byType(Scrollable).first
            : find.byType(Scrollable).last,
      );
    }
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  Future<void> tap(String label) async {
    final target = find.text(label);
    await visible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> section(String title) async {
    if (!wide && find.text('Settings').evaluate().isEmpty) {
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
    }
    final target = find.widgetWithText(ListTile, title);
    await visible(target, categories: true);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> close() async {
    if (!wide && find.text('Settings').evaluate().isEmpty) {
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    // Native route disposal can trail the first visible library frame.
    await _wait(
      tester,
      () => find.byType(BackButton, skipOffstage: false).evaluate().isEmpty,
    );
  }
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  for (var frame = 0; frame < 200; frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 25));
    if (ready()) return;
  }
  fail('Timed out waiting for native Settings state.');
}

/// Native preferences flows keep imported books and normalized progress intact.
void registerSettingsTests() {
  testWidgets(
    'global settings change theme voice speed and retain imported books',
    (tester) async {
      final app = await NativeTestApp.launch(tester);
      await app.openBook('Unicode Test');
      await app.advance();
      final anchor = app.viewport.navigation.leadingPosition;
      await app.closeReader();
      final original = app.book('Unicode Test');
      expect(original.lastPosition, anchor);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      final flow = _SettingsFlow(tester);
      for (final title in [
        'Account',
        'Appearance',
        'Reading',
        'Narration',
        'Library',
        'Usage & allowance',
        'Storage & privacy',
        'About',
      ]) {
        await flow.section(title);
      }
      await _wait(
        tester,
        () => find.textContaining('Version ').evaluate().isNotEmpty,
      );
      expect(find.text('Version unavailable'), findsNothing);
      await flow.tap('Open-source licenses');
      expect(find.byType(LicensePage), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await flow.tap('Reset preferences');
      await flow.tap('Cancel');
      await flow.section('Storage & privacy');
      await flow.tap('Clear narration cache');
      await flow.tap('Cancel');
      await flow.section('Reading');
      for (final label in ['Pages', 'Page Flip', 'Scroll']) {
        await flow.tap(label);
        expect(app.book('Unicode Test').lastPosition, anchor);
      }
      await flow.tap('Serif font');
      expect(app.controller.preferences.settings.serif, isFalse);
      await flow.visible(find.byType(Slider));
      await tester.drag(find.byType(Slider), const Offset(60, 0));
      await tester.pumpAndSettle();
      expect(app.controller.preferences.settings.fontSize, isNot(100));
      final sample = find.textContaining('The quiet room held');
      await flow.visible(sample);
      expect(tester.widget<Text>(sample).style!.fontFamily, 'DM Sans');
      await flow.section('Narration');
      await flow.tap('Cedar');
      await flow.tap('1.5×');
      expect(app.controller.preferences.settings.narrationVoice, 'cedar');
      expect(app.controller.preferences.settings.narrationSpeed, 1.5);
      await flow.section('Appearance');
      await flow.tap('Sepia');
      expect(app.controller.preferences.settings.theme, ReadingTheme.sepia);
      await app.capture('settings-sepia');
      await flow.close();
      await tester.enterText(find.byType(TextField), 'Unicode');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await flow.section('Library');
      await flow.tap('Finished');
      await flow.close();
      expect(find.text('No books match these controls.'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text ??
            tester
                .widget<EditableText>(find.byType(EditableText))
                .controller
                .text,
        'Unicode',
      );
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await flow.section('Library');
      await flow.tap('All');
      await flow.tap('Title');
      await flow.close();
      expect(
        find.byKey(ValueKey('library-book-${original.hash}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('library-book-${app.book('Novel').hash}')),
        findsNothing,
      );
      await app.openBook('Unicode Test');
      expect(app.textPaints, findsWidgets);
      expect(app.viewport.settings.serif, isFalse);
      expect(
        app.viewport.settings.fontSize,
        app.controller.preferences.settings.fontSize,
      );
      expect(app.viewport.settings.mode, ReadingMode.scroll);
      expect(app.viewport.navigation.leadingPosition, anchor);
      expect(app.book('Unicode Test').lastPosition, anchor);
      await app.closeReader();
    },
  );

  testWidgets(
    'settings browsing reset and cache clearing preserve committed narration positions',
    (tester) async {
      final app = await NativeTestApp.launch(tester, narration: true);
      final session = app.controller.narration!;
      final native = session.player as NativeNarrationPlayer;
      final api = session.api as FakeNarrationApi;
      api.gate = Completer<Uint8List>()..complete(testWav(samples: 24000 * 60));
      await app.openBook('Unicode Test');
      final initial = app.viewport.navigation.leadingPosition;
      await app.advance();
      final anchor = app.viewport.navigation.leadingPosition;
      final book = app.book('Unicode Test');
      expect(anchor, isNotNull);
      expect(anchor, isNot(initial));
      await app.runWithFrames(() => app.controller.consentToNarration(book));
      await app.runWithFrames(session.play);
      await _wait(tester, () => session.status == NarrationStatus.playing);
      await app.closeReader();
      expect(app.book('Unicode Test').lastPosition, anchor);
      final consent = session.manifest.cloudBookId;
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      final flow = _SettingsFlow(tester);
      await flow.section('Appearance');
      await flow.tap('Sepia');
      expect(session.status, NarrationStatus.playing);
      await flow.section('Reading');
      expect(session.status, NarrationStatus.playing);
      await flow.section('Narration');
      final requests = api.requests.length;
      await flow.tap('1.5×');
      await _wait(tester, () => session.manifest.speed == 1.5);
      expect(session.status, NarrationStatus.playing);
      expect(native.playbackState.value.speed, 1.5);
      expect(api.requests.length, requests);
      await flow.tap('Cedar');
      await _wait(tester, () => session.status == NarrationStatus.paused);
      expect(session.manifest.chunkId, isNull);
      expect(session.manifest.offsetMs, 0);
      expect(app.book('Unicode Test').lastPosition, anchor);
      await flow.close();
      await tester.tap(find.byTooltip('Play narration'));
      await _wait(tester, () => session.status == NarrationStatus.playing);
      expect(session.manifest.voice, 'cedar');
      expect(api.voices.last, 'cedar');
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await flow.section('Narration');
      await app.capture('settings-narration');
      final cached = await tester.runAsync(app.controller.narrationCacheBytes);
      expect(cached, greaterThan(0));
      await flow.section('About');
      await flow.tap('Reset preferences');
      await app.capture('settings-reset-confirmation');
      await flow.tap('Cancel');
      expect(session.status, NarrationStatus.playing);
      expect(app.controller.preferences.settings.narrationVoice, 'cedar');
      expect(app.controller.preferences.settings.narrationSpeed, 1.5);
      expect(app.book('Unicode Test').lastPosition, anchor);
      expect(session.manifest.cloudBookId, consent);
      expect(await tester.runAsync(app.controller.narrationCacheBytes), cached);
      await flow.tap('Reset preferences');
      await tester.tap(find.widgetWithText(FilledButton, 'Reset preferences'));
      await _wait(
        tester,
        () =>
            session.status == NarrationStatus.paused &&
            app.controller.preferences.settings.narrationVoice == 'marin',
      );
      expect(
        app.controller.preferences.settings.toJson(),
        const ReaderSettings().toJson(),
      );
      expect(session.manifest.cloudBookId, consent);
      expect(await tester.runAsync(app.controller.narrationCacheBytes), cached);
      expect(app.book('Unicode Test').lastPosition, anchor);
      await flow.section('Storage & privacy');
      await flow.tap('Clear narration cache');
      await app.capture('settings-cache-confirmation');
      await flow.tap('Cancel');
      expect(await tester.runAsync(app.controller.narrationCacheBytes), cached);
      expect(session.manifest.cloudBookId, consent);
      expect(app.book('Unicode Test').lastPosition, anchor);
      expect(session.status, NarrationStatus.paused);
      await flow.tap('Clear narration cache');
      await tester.tap(find.widgetWithText(FilledButton, 'Clear cache'));
      await _wait(tester, () => find.text('0.0 MiB').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(await tester.runAsync(app.controller.narrationCacheBytes), 0);
      expect(native.playbackState.value.playing, isFalse);
      expect(native.playbackState.value.processingState.name, 'idle');
      expect(session.status, isNot(NarrationStatus.playing));
      expect(session.manifest.chunkId, isNull);
      expect(session.manifest.offsetMs, 0);
      expect(session.manifest.cloudBookId, consent);
      expect(app.book('Unicode Test').lastPosition, anchor);
      final saved = await tester.runAsync(
        () => session.store.load(app.book('Unicode Test')),
      );
      expect(saved!.cloudBookId, consent);
      expect(saved.chunkId, isNull);
      expect(saved.offsetMs, 0);
      expect(saved.anchor, anchor);
      await app.capture('settings-cache-cleared');
      await flow.close();
      await app.openBook('Unicode Test');
      expect(app.viewport.navigation.leadingPosition, anchor);
      await app.closeReader();
    },
  );
}
