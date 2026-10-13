import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/illustrations/illustration_scene.dart';
import 'package:reader/reader/illustration_figure_view.dart';

import '../support/native_analysis_scenario.dart';
import '../support/native_illustration_api.dart';
import '../support/native_test_app.dart';

/// Per-book source selection, replacement and offline gallery scenarios.
///
/// Cloud behavior is a deterministic fixture; import, indexing, storage, image
/// decoding, gating, polling and every interaction below are the real app.
void registerIllustrationTests() {
  testWidgets(
    'default preprocessing completes without opening books or prompting for authentication',
    runDefaultPreprocessingScenario,
  );

  testWidgets(
    'cancel uploads no prose, then each source saves per book without touching admitted work or art',
    (tester) async {
      final api = NativeIllustrationApi();
      final app = await NativeTestApp.launch(tester, illustrationApi: api);
      await app.openBook('Unicode Test');
      final book = app.book('Unicode Test');

      await _openIllustrations(tester);
      expect(find.text('Illustrate this book?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.admissions, isEmpty);
      expect(api.confirmations, isEmpty);

      await _openIllustrations(tester);
      await tester.tap(find.text('Enable illustrations'));
      await _until(
        tester,
        () => api.admissions.isNotEmpty,
        'chapter admission',
      );
      await tester.pumpAndSettle();
      expect(api.confirmations.single.providerId, 'openai');
      final admitted = api.admissions.map((entry) => entry.id).toList();

      await _readUntilScene(app, tester, book);
      final scene = _scene(app, book);
      final artwork = scene.localImagePath!;
      final anchor = app.viewport.navigation.leadingPosition;

      await _openIllustrations(tester);
      const choices = [
        ('google', 'Google'),
        ('seedream', 'ByteDance'),
        ('qwen', 'Alibaba'),
        ('xai', 'xAI'),
        ('flux', 'BFL'),
        ('diagnostic', 'Pipeline test'),
        ('openai', 'OpenAI'),
      ];
      for (final (index, (id, label)) in choices.indexed) {
        await tester.tap(find.text('Illustration settings'));
        await _until(
          tester,
          () => find
              .byKey(const ValueKey('illustration-provider-selector'))
              .evaluate()
              .isNotEmpty,
          'the settings dialog',
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('illustration-provider-selector')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining(label).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await _until(
          tester,
          () => api.confirmations.length == index + 2,
          'the server-confirmed $id profile',
        );
        await tester.pumpAndSettle();
        final saved = app.controller.illustrations.manifestFor(book).profile!;
        expect(saved.providerId, id);
        expect(saved.revision, index + 2);
      }

      // Provider changes never re-admit scheduled chapters or replace ready art.
      expect(api.admissions.map((entry) => entry.id), admitted);
      expect(_scene(app, book).localImagePath, artwork);
      expect(File(artwork).existsSync(), isTrue);
      expect(app.viewport.navigation.leadingPosition, anchor);

      await app.restart();
      final reopened = app.controller.illustrations.manifestFor(
        app.book('Unicode Test'),
      );
      expect(reopened.profile!.providerId, 'openai');
      expect(reopened.scenes.single.localImagePath, artwork);
    },
  );

  testWidgets(
    'regeneration replaces art after idle polling, failure keeps it, and the gallery works offline',
    (tester) async {
      final api = NativeIllustrationApi();
      final app = await NativeTestApp.launch(tester, illustrationApi: api);
      await app.openBook('Unicode Test');
      final book = app.book('Unicode Test');
      await _openIllustrations(tester);
      await tester.tap(find.text('Enable illustrations'));
      await _until(
        tester,
        () => api.admissions.isNotEmpty,
        'chapter admission',
      );
      await _readUntilScene(app, tester, book);
      final first = _scene(app, book);
      final anchor = app.viewport.navigation.leadingPosition;

      // A rejected submission is reported without changing artwork.
      api.rejectNextRegeneration = true;
      await _openIllustrations(tester);
      await _regenerateFromGallery(tester, 'The quiet room, version 1');
      await _until(
        tester,
        () => find
            .text('Could not submit replacement. Try again.')
            .evaluate()
            .isNotEmpty,
        'the safe regeneration error',
      );
      expect(_scene(app, book).localImagePath, first.localImagePath);
      await _closeGallery(tester);

      // Success is committed only by the reader's own idle polling.
      await _openIllustrations(tester);
      await _regenerateFromGallery(tester, 'The quiet room, version 1');
      await _until(tester, () => api.regenerations.length == 1, 'submission');
      await _until(
        tester,
        () => _scene(app, book).regenerating,
        'the pending replacement to be recorded',
      );
      api.finishRegeneration(success: true);
      await _until(
        tester,
        () => _scene(app, book).generation == 2,
        'the polled replacement',
      );
      final replaced = _scene(app, book);
      expect(replaced.regenerating, isFalse);
      expect(replaced.pendingGeneration, isNull);
      expect(File(replaced.localImagePath!).existsSync(), isTrue);
      expect(replaced.localImagePath, endsWith('.2.jpg'));
      // Old art is deleted only after the new manifest commits.
      await _until(
        tester,
        () => !File(first.localImagePath!).existsSync(),
        'the superseded artwork cleanup',
      );
      expect(app.viewport.navigation.leadingPosition, anchor);
      await _closeGallery(tester);

      // Terminal failure clears progress and keeps the committed replacement.
      await _openIllustrations(tester);
      await _regenerateFromGallery(tester, 'The quiet room, version 2');
      await _until(tester, () => api.regenerations.length == 2, 'submission');
      api.finishRegeneration(success: false);
      await _until(
        tester,
        () => !_scene(app, book).regenerating,
        'the failed replacement to clear',
      );
      expect(_scene(app, book).generation, 2);
      expect(_scene(app, book).localImagePath, replaced.localImagePath);
      expect(File(replaced.localImagePath!).existsSync(), isTrue);
      await _closeGallery(tester);

      // Offline reopening reads only local files.
      api.offline = true;
      await _openIllustrations(tester);
      expect(find.text('The quiet room, version 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(app.viewport.navigation.leadingPosition, anchor);
    },
  );

  testWidgets(
    'placeholder becomes inline art and the gallery jumps to its scene',
    (tester) async {
      final api = NativeIllustrationApi()..holdGeneration = true;
      final app = await NativeTestApp.launch(tester, illustrationApi: api);
      await app.openBook('Unicode Test');
      final book = app.book('Unicode Test');
      await _openIllustrations(tester);
      await tester.tap(find.text('Enable illustrations'));
      await _until(
        tester,
        () => find.text('Illustrating this scene…').evaluate().isNotEmpty,
        'the generating placeholder',
      );
      expect(_scene(app, book).localImagePath, isNull);

      api.holdGeneration = false;
      await _until(
        tester,
        () =>
            _scene(app, book).localImagePath != null &&
            find.byType(IllustrationFigureView).evaluate().isNotEmpty &&
            find.text('Illustrating this scene…').evaluate().isEmpty,
        'the inline art to replace the placeholder',
      );
      final scene = _scene(app, book);
      expect(find.byType(Image), findsWidgets);

      await app.advance();
      await app.advance();
      await _openIllustrations(tester);
      await tester.tap(find.text('The quiet room, version 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Go to scene'));
      await tester.pumpAndSettle();
      final position = app.viewport.navigation.leadingPosition!;
      expect(position.blockId, scene.anchor.paragraphId);
      expect(position.offset, 0);
    },
  );
}

IllustrationScene _scene(NativeTestApp app, book) =>
    app.controller.illustrations.manifestFor(book).scenes.single;

Future<void> _openIllustrations(WidgetTester tester) async {
  expect(
    find.text('Illustrated scenes'),
    findsNothing,
    reason: 'gallery left open',
  );
  await tester.tap(find.byTooltip('AI illustrations'));
  await tester.pumpAndSettle();
  // Setup performs real sign-in and index I/O before its dialog or sheet shows.
  await _until(
    tester,
    () =>
        find.text('Illustrate this book?').evaluate().isNotEmpty ||
        find.text('Illustrated scenes').evaluate().isNotEmpty,
    'the illustration presentation',
  );
  await tester.pumpAndSettle();
}

Future<void> _readUntilScene(
  NativeTestApp app,
  WidgetTester tester,
  book,
) async {
  for (var page = 0; page < 6; page++) {
    await app.advance();
    for (var frame = 0; frame < 60; frame++) {
      final scenes = app.controller.illustrations.manifestFor(book).scenes;
      if (scenes.isNotEmpty && scenes.single.localImagePath != null) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
  fail('The passed scene was never downloaded.');
}

Future<void> _regenerateFromGallery(WidgetTester tester, String caption) async {
  await tester.tap(find.text(caption));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(TextButton, 'Regenerate'));
  await tester.pump();
}

Future<void> _closeGallery(WidgetTester tester) async {
  // The gallery may already have closed itself; only dismiss a visible one.
  if (find.text('Illustrated scenes').evaluate().isEmpty) return;
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
  for (var attempt = 0; attempt < 3; attempt++) {
    if (find.text('Illustrated scenes').evaluate().isEmpty) return;
    // The sheet may fill the screen, so use the user's swipe-down dismissal.
    await tester.fling(
      find.text('Illustrated scenes'),
      const Offset(0, 700),
      2000,
    );
    await tester.pumpAndSettle();
  }
}

/// Real I/O completes outside the fake frame clock, so wait through both.
Future<void> _until(
  WidgetTester tester,
  bool Function() done,
  String description,
) async {
  for (var frame = 0; frame < 400; frame++) {
    if (done()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail('Timed out waiting for $description.');
}
