import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/illustrations/document_text_indexer.dart';
import 'package:reader/illustrations/gate.dart';
import 'package:reader/illustrations/scene_anchor.dart';
import 'package:reader/narration/native_narration_player.dart';
import 'package:reader/narration/narration_sheet.dart';
import 'package:reader/narration/narration_registration.dart';
import 'package:reader/narration/narration_cache_key.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/text/block_slice.dart';
import 'package:reader/text/text_position.dart';
import 'package:reader/narration/session.dart';
import 'package:reader/text/viewport.dart';

import '../../test/fixtures/narration_audio.dart';
import '../../test/support/cloud_identity_fake.dart';
import '../../test/support/fake_account_api.dart';
import '../../test/support/fake_narration_api.dart';
import '../support/native_test_app.dart';
import '../support/apple_narration_probe.dart';

/// Actual Apple local generation plus the retained legacy cloud/privacy fixture.
void registerNarrationTests() {
  testWidgets(
    'installed Apple voices produce probed PCM and native sentence ranges',
    (tester) async {
      final app = await NativeTestApp.launch(tester, localNarration: true);
      await app.runWithFrames(() => probeAppleNarration(app));
      final session = app.controller.narration!;
      final api = session.api as FakeNarrationApi;
      expect(api.registrations, 0);
      expect(api.requests, isEmpty);
      expect(session.manifest.account, isNull);
      expect(session.manifest.cloudBookId, isNull);
    },
    skip: !Platform.isIOS,
  );

  testWidgets(
    'local short clips play without cloud identity and retain playback ownership',
    (tester) async {
      final first =
          'This first sentence is deliberately long enough to keep playing while the reader tests its transport controls, presentation modes, library continuation, and complete logical anchor restoration without prematurely reaching a natural audio ending.';
      final overlong =
          '${List.filled(100, 'a longer clause with exact source whitespace').join(', ')}.';
      final paragraph = [
        first,
        'Dr. Lee paid 3.14 and said, “Keep this exact source.”',
        'Another short sentence follows.',
        overlong,
        ...List.generate(
          8,
          (index) => 'Later sentence $index stays in this same paragraph.',
        ),
      ].join(' ');
      final app = await NativeTestApp.launch(
        tester,
        localNarration: true,
        textBytes: Uint8List.fromList(utf8.encode(paragraph)),
      );
      final source = app.localNarrationSource!;
      expect(source.voices, isNotEmpty);
      final preferred = source.defaultVoice ?? source.voices.first.identifier;
      if (app.controller.preferences.settings.narrationVoice != preferred) {
        await app.runWithFrames(
          () => app.controller.preferences.configure(narrationVoice: preferred),
        );
      }
      final book = app.book('Unicode Test');
      await app.openBook('Unicode Test');
      await tester.tap(find.byTooltip('Listen'));
      final transport = find.byKey(const ValueKey('narration-transport'));
      await _waitForControl(tester, transport);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      final session = app.controller.narration!;
      final api = session.api as FakeNarrationApi;
      final initial = app.controller.catalog.books
          .firstWhere((item) => item.hash == book.hash)
          .lastPosition;
      final section = await session.documents.loadSection(
        book.path,
        session.document!.sections.first.id,
      );
      final units = await source.units(section);
      expect(units.length, greaterThan(10));
      expect(
        units.map((unit) => unit.chunk.text).join(),
        section.blocks.map((block) => block.text).join(),
      );
      await app.runWithFrames(session.play);
      expect(session.status, NarrationStatus.playing);
      expect(session.manifest.account, isNull);
      expect(session.manifest.cloudBookId, isNull);
      expect(api.registrations, 0);
      expect(api.requests, isEmpty);
      final active = session.activeChunk!;
      expect(active.text.length, lessThanOrEqualTo(300));
      expect(active.text.length, lessThan(paragraph.length));
      final directory = Directory(
        '${app.root.path}/books/${book.hash}/narration',
      );
      final completed = await directory
          .list()
          .where((file) => file.path.endsWith('.wav'))
          .length;
      expect(
        completed,
        lessThan(units.length),
      ); // No whole-paragraph startup barrier.
      final unit = units.firstWhere((unit) => unit.chunk.id == active.id);
      final asset = await session.store.cached(
        book,
        narrationCacheKey(
          book,
          session.manifest,
          active,
          sentence: unit.sentence,
        ),
      );
      expect(asset, isNotNull);
      if (asset!.timing != null) {
        expect(asset.timing!.preferredCues, isNotEmpty);
        expect(
          asset.timing!.preferredCues.every(
            (cue) =>
                cue.range.start.offset >= active.start.offset &&
                cue.range.end.offset <= active.end.offset,
          ),
          isTrue,
        );
      }
      for (final mode in ReadingMode.values) {
        await app.runWithFrames(
          () => app.controller.preferences.configure(mode: mode),
        );
        await tester.pump();
        expect(session.status, NarrationStatus.playing);
        final paints = find.byWidgetPredicate(
          (widget) => widget is BlockSlice && widget.narrationRange != null,
        );
        expect(paints, findsWidgets);
        expect(
          app.controller.catalog.books
              .firstWhere((item) => item.hash == book.hash)
              .lastPosition,
          initial,
        );
      }
      final keyBeforeSpeed = session.manifest.chunkId;
      await app.runWithFrames(
        () => app.controller.preferences.configure(narrationSpeed: 1.5),
      );
      expect(
        (session.player as NativeNarrationPlayer).playbackState.value.speed,
        1.5,
      );
      expect(session.manifest.chunkId, keyBeforeSpeed);
      await app.closeReader();
      expect(find.byTooltip('Pause narration'), findsOneWidget);
      expect(session.ownsPosition(book), isTrue);
      await app.openBook('Unicode Test');
      await tester.pump();
      expect(session.status, NarrationStatus.playing);
      expect(
        app.controller.catalog.books
            .firstWhere((item) => item.hash == book.hash)
            .lastPosition,
        initial,
      );
      await _waitForNativeState(
        app,
        () => session.player.position > Duration.zero,
        'the native playback clock to advance before interruption',
      );
      await app.runWithFrames(session.pause);
      final interruptedOffset = session.manifest.offsetMs;
      expect(interruptedOffset, greaterThan(0));
      await app.runWithFrames(session.play);
      expect(
        session.player.position.inMilliseconds,
        greaterThanOrEqualTo(interruptedOffset - 1),
      );
      await app.runWithFrames(
        () => session.seek(const Duration(milliseconds: 650)),
      );
      expect(
        app.controller.catalog.books
            .firstWhere((item) => item.hash == book.hash)
            .lastPosition,
        initial,
      );
      await app.runWithFrames(session.pause);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is BlockSlice && widget.narrationRange != null,
        ),
        findsNothing,
      );
      await app.runWithFrames(session.play);
      expect(session.status, NarrationStatus.playing);
      await app.runWithFrames(session.pause);
      final other = source.voices
          .where((voice) => voice.identifier != preferred)
          .firstOrNull;
      if (other != null) {
        await app.runWithFrames(
          () => app.controller.preferences.configure(
            narrationVoice: other.identifier,
          ),
        );
        expect(session.status, NarrationStatus.paused);
        expect(session.manifest.chunkId, isNull);
        expect(session.manifest.offsetMs, 0);
      }
      await app.runWithFrames(session.clear);
      expect(await session.store.cachedBytes(book), 0);
      expect(
        app.controller.catalog.books
            .firstWhere((item) => item.hash == book.hash)
            .lastPosition,
        initial,
      );
      final playback = session.play();
      await app.runWithFrames(() => app.controller.delete(book));
      await app.runWithFrames(() => playback);
      expect(await File(book.path).exists(), isFalse);
      expect(
        await Directory('${app.root.path}/books/${book.hash}').exists(),
        isFalse,
      );
      expect(api.registrations, 0);
      expect(api.requests, isEmpty);
    },
    skip: !Platform.isIOS,
  );

  testWidgets(
    'local natural clip endings alone commit exact anchors and paragraph gates',
    (tester) async {
      final paragraph =
          'Hello. ${List.filled(12, 'One two three four five six seven eight nine ten').join(', ')}.';
      final app = await NativeTestApp.launch(
        tester,
        localNarration: true,
        textBytes: Uint8List.fromList(utf8.encode(paragraph)),
      );
      final book = app.book('Unicode Test');
      await app.openBook('Unicode Test');
      final session = app.controller.narration!;
      await app.runWithFrames(() => session.attach(book));
      final section = await session.documents.loadSection(
        book.path,
        session.document!.sections.first.id,
      );
      final units = await app.localNarrationSource!.units(section);
      final index = await DocumentTextIndexer(store: session.documents)
          .index(sourcePath: book.path, bookHash: book.hash);
      final block = section.blocks.first;
      final gateAnchor = SceneAnchor(
        href: section.id,
        spineOrdinal: 0,
        paragraphId: block.id,
        cssSelector: '#${block.id}',
        fallbackProgression: 1,
      );
      TextPosition? position() => app.controller.catalog.books
          .firstWhere((item) => item.hash == book.hash)
          .lastPosition;
      final initial = position();
      await app.runWithFrames(
        () => app.controller.preferences.configure(narrationSpeed: 2),
      );
      await app.runWithFrames(session.play);
      expect(position(), initial);
      final first = units.first.chunk;
      expect(session.activeChunk!.id, first.id);
      await _waitForNativeState(
        app,
        () => position() == first.end,
        'the short native clip to naturally commit its exact ending',
      );
      await app.runWithFrames(session.pause);
      expect(position(), first.end);
      expect(
        const IllustrationGate().hasPassed(
          anchor: gateAnchor,
          index: index,
          position: position()!,
        ),
        isFalse,
      );
      final longUnits = units
          .where((unit) => unit.sentence == units[1].sentence)
          .toList();
      expect(longUnits.length, greaterThan(1));
      expect(longUnits.first.chunk.end.offset, lessThan(block.text.length));
      expect(units.map((unit) => unit.chunk.text).join(), block.text);
      expect(units.every((unit) => unit.chunk.text.length <= 300), isTrue);
      final middle = longUnits.first.chunk;
      await app.runWithFrames(() => session.playFrom(middle.start));
      expect(position(), first.end);
      await _waitForNativeState(
        app,
        () => position() == middle.end,
        'an intermediate long-sentence clip to naturally complete',
      );
      await app.runWithFrames(session.pause);
      expect(position(), middle.end);
      expect(
        const IllustrationGate().hasPassed(
          anchor: gateAnchor,
          index: index,
          position: position()!,
        ),
        isFalse,
      );
      // A real native tail ending after seeking is not proof of hearing a clip.
      await app.runWithFrames(() => session.playFrom(longUnits[1].chunk.start));
      final duration = session.player.duration!;
      await app.runWithFrames(
        () => session.seek(duration - const Duration(milliseconds: 100)),
      );
      expect(position(), middle.end);
      await _waitForNativeState(
        app,
        () => session.status == NarrationStatus.paused,
        'the seek-tainted native ending to pause without a text commit',
      );
      expect(position(), middle.end);
      final api = session.api as FakeNarrationApi;
      expect(api.registrations, 0);
      expect(api.requests, isEmpty);
    },
    skip: !Platform.isIOS,
  );

  testWidgets(
    'markerless real Apple WAV uses enclosing sentence in every reading mode',
    (tester) async {
      final paragraph =
          '${List.filled(14, 'The same enclosing sentence continues across this exact clause').join(', ')}.';
      final app = await NativeTestApp.launch(
        tester,
        localNarration: true,
        textBytes: Uint8List.fromList(utf8.encode(paragraph)),
      );
      final book = app.book('Unicode Test');
      await app.openBook('Unicode Test');
      final session = app.controller.narration!;
      await app.runWithFrames(() => session.attach(book));
      final section = await session.documents.loadSection(
        book.path,
        session.document!.sections.first.id,
      );
      final source = app.localNarrationSource!;
      final units = await source.units(section);
      final unit = units.first;
      expect(units.length, greaterThan(1));
      expect(unit.sentence.end.offset, greaterThan(unit.chunk.end.offset));
      final key = narrationCacheKey(
        book,
        session.manifest,
        unit.chunk,
        sentence: unit.sentence,
      );
      await app.runWithFrames(() async {
        final asset = await source.render(
          book,
          session.manifest,
          unit,
          session.store,
          generation: 9100,
          isCurrent: () => true,
        );
        // Remove only this fixture-owned companion. The WAV still comes from
        // Apple's real buffer synthesis and is replayed by the native player.
        final companion = File(
          '${File(asset.path).parent.path}/$key.timing.json',
        );
        if (await companion.exists()) await companion.delete();
      });
      final markerless = await session.store.cached(book, key);
      expect(markerless, isNotNull);
      expect(markerless!.timing, isNull);
      final initial = app.controller.catalog.books
          .firstWhere((item) => item.hash == book.hash)
          .lastPosition;
      await app.runWithFrames(
        () => app.controller.preferences.configure(narrationSpeed: .75),
      );
      await app.runWithFrames(() => session.playFrom(unit.chunk.start));
      for (final mode in ReadingMode.values) {
        await app.runWithFrames(
          () => app.controller.preferences.configure(mode: mode),
        );
        await tester.pump();
        expect(session.status, NarrationStatus.playing);
        expect(session.activeChunk!.id, unit.chunk.id);
        expect(session.activeHighlight, unit.sentence);
        final painted = find.byWidgetPredicate(
          (widget) => widget is BlockSlice && widget.narrationRange != null,
        );
        expect(painted, findsWidgets);
        for (final slice in tester.widgetList<BlockSlice>(painted)) {
          expect(slice.block.block.id, unit.sentence.start.blockId);
          expect(
            slice.narrationRange,
            TextSelection(
              baseOffset: slice.start > unit.sentence.start.offset
                  ? slice.start
                  : unit.sentence.start.offset,
              extentOffset: slice.end < unit.sentence.end.offset
                  ? slice.end
                  : unit.sentence.end.offset,
            ),
          );
        }
        expect(
          app.controller.catalog.books
              .firstWhere((item) => item.hash == book.hash)
              .lastPosition,
          initial,
        );
      }
      await app.runWithFrames(session.pause);
      final api = session.api as FakeNarrationApi;
      expect(api.registrations, 0);
      expect(api.requests, isEmpty);
    },
    skip: !Platform.isIOS,
  );

  testWidgets(
    'active paragraph and playback status stay visible without committing progress',
    (tester) async {
      final app = await NativeTestApp.launch(tester, narration: true);
      final book = app.book('Unicode Test');
      final session = app.controller.narration!;
      final api = session.api as FakeNarrationApi;
      api.gate = Completer<Uint8List>()..complete(testWav(samples: 24000 * 60));
      await app.openBook('Unicode Test');
      await tester.tap(find.byTooltip('Listen'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      final committed = app.controller.catalog.books
          .firstWhere((item) => item.hash == book.hash)
          .lastPosition;
      final section = await session.documents.loadSection(
        book.path,
        session.document!.sections.first.id,
      );
      final target = TextPosition(
        sectionId: section.id,
        blockId: section.blocks[8].id,
      );
      final status = find.byKey(const ValueKey('reader-narration-status'));
      for (final mode in ReadingMode.values) {
        await app.runWithFrames(
          () => app.controller.preferences.configure(mode: mode),
        );
        await tester.pumpAndSettle();
        final bounds = tester.getRect(find.byType(TextViewport));
        await app.runWithFrames(() => session.playFrom(target));
        await tester.pump();
        expect(session.status, NarrationStatus.playing);
        expect(find.bySemanticsLabel('Narration playing'), findsOneWidget);
        final highlighted = find.byWidgetPredicate(
          (widget) => widget is BlockSlice && widget.narrationRange != null,
        );
        expect(highlighted, findsOneWidget);
        final slice = tester.widget<BlockSlice>(highlighted);
        expect(slice.block.block.id, target.blockId);
        expect(tester.getRect(highlighted).overlaps(bounds), isTrue);
        await tester.tap(find.byTooltip('Hide reading controls'));
        await tester.pumpAndSettle();
        expect(status, findsOneWidget);
        expect(tester.getRect(find.byType(TextViewport)), bounds);
        expect(find.bySemanticsLabel('Listen'), findsNothing);
        await app.runWithFrames(session.pause);
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('Narration paused'), findsOneWidget);
        expect(highlighted, findsNothing);
        expect(
          app.controller.catalog.books
              .firstWhere((item) => item.hash == book.hash)
              .lastPosition,
          committed,
        );
        await tester.tap(find.byTooltip('Show reading controls'));
        await tester.pumpAndSettle();
      }
      // A new voice cannot reuse the old cached chunk; the failed request must
      // show buffering/error without highlighting or committing an old passage.
      await app.runWithFrames(
        () => app.controller.preferences.configure(narrationVoice: 'cedar'),
      );
      api.offline = true;
      await app.runWithFrames(session.play);
      await tester.pumpAndSettle();
      expect(session.status, NarrationStatus.buffering);
      expect(find.bySemanticsLabel('Narration buffering'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is BlockSlice && widget.narrationRange != null,
        ),
        findsNothing,
      );
      await tester.tap(find.byTooltip('Listen'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(NarrationSheet),
          matching: find.textContaining('Offline'),
        ),
        findsOneWidget,
      );
      expect(
        app.controller.catalog.books
            .firstWhere((item) => item.hash == book.hash)
            .lastPosition,
        committed,
      );
    },
  );

  testWidgets(
    'listening sheet exposes loading and errors and applies global voice and speed',
    (tester) async {
      final app = await NativeTestApp.launch(tester, narration: true);
      final book = app.book('Unicode Test');
      final session = app.controller.narration!;
      final api = session.api as FakeNarrationApi;
      final registration = Completer<NarrationRegistration>();
      api.registrationGate = registration;
      await app.openBook('Unicode Test');
      final committed = app.controller.catalog.books
          .firstWhere((item) => item.hash == book.hash)
          .lastPosition;
      await tester.tap(find.byTooltip('Listen'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('narration-loading')), findsOneWidget);
      registration.complete(
        const NarrationRegistration('account', 'cloud-book', 500000),
      );
      final transport = find.byWidgetPredicate(
        (widget) =>
            widget is FilledButton &&
            widget.key == const ValueKey('narration-transport') &&
            widget.onPressed != null,
      );
      await _waitForControl(tester, transport);
      await tester.pumpAndSettle();
      await app.capture('narration-sheet');
      final audio = Completer<Uint8List>();
      api.gate = audio;
      await tester.tap(transport);
      await tester.pump(const Duration(milliseconds: 200));
      expect(session.status, NarrationStatus.buffering);
      expect(find.byKey(const ValueKey('narration-loading')), findsOneWidget);
      audio.completeError(StateError('Offline'));
      final retry = find.byKey(const ValueKey('narration-retry'));
      await _waitForControl(tester, retry);
      expect(
        find.descendant(
          of: find.byType(NarrationSheet),
          matching: find.textContaining('Offline'),
        ),
        findsOneWidget,
      );
      api.gate = Completer<Uint8List>()..complete(testWav(samples: 24000 * 60));
      await tester.tap(retry);
      await app.runWithFrames(() async {
        for (var attempt = 0; attempt < 250; attempt++) {
          if (session.status == NarrationStatus.playing) return;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        fail('Narration did not start after retry.');
      });
      await tester.pump();
      expect(session.player.duration, const Duration(seconds: 60));
      final requestsBeforeSpeed = api.requests.length;
      final speed = find.byType(DropdownButtonFormField<double>);
      await tester.ensureVisible(speed);
      await tester.tap(speed);
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5×').last);
      await tester.pumpAndSettle();
      expect(app.controller.preferences.settings.narrationSpeed, 1.5);
      expect(
        (session.player as NativeNarrationPlayer).playbackState.value.speed,
        1.5,
      );
      expect(api.requests.length, requestsBeforeSpeed);
      final voice = find.byType(DropdownButtonFormField<String>).first;
      await tester.ensureVisible(voice);
      await tester.tap(voice);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cedar').last);
      await tester.pumpAndSettle();
      expect(app.controller.preferences.settings.narrationVoice, 'cedar');
      expect(session.status, NarrationStatus.paused);
      expect(session.manifest.chunkId, isNull);
      expect(
        app.controller.catalog.books
            .firstWhere((item) => item.hash == book.hash)
            .lastPosition,
        committed,
      );
    },
  );

  testWidgets(
    'registration, native media controls, offline replay and deletion preserve reading progress',
    (tester) async {
      final identity = FakeCloudIdentity();
      final account = FakeAccountApi();
      final app = await NativeTestApp.launch(
        tester,
        narration: true,
        cloudIdentity: identity,
        accountApi: account,
      );
      final book = app.book('Unicode Test');
      final session = app.controller.narration!;
      final api = session.api as FakeNarrationApi;
      // Route transitions must not consume the whole fixture before media actions.
      api.gate = Completer<Uint8List>()..complete(testWav(samples: 24000 * 60));
      await app.openBook('Unicode Test');
      await tester.tap(find.byTooltip('Listen'));
      await tester.pumpAndSettle();
      expect(find.byType(NarrationSheet), findsOneWidget);
      expect(find.text('Listen with AI narration?'), findsNothing);
      expect(api.registrations, 1);
      expect(api.requests, isEmpty);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
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
      expect(identity.signOuts, 1);
      await app.runWithFrames(app.controller.deleteCloudAccount);
      expect(account.deletions, 1);
      expect(app.controller.catalog.books, hasLength(1));
    },
  );
}

Future<void> _waitForControl(WidgetTester tester, Finder control) async {
  for (var frame = 0; frame < 200; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (control.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for listening controls.');
}

/// Waits for observed native completion/anchors, not guessed speech duration.
/// Each bounded action yields frames; assertions remain outside active pumps.
Future<void> _waitForNativeState(
  NativeTestApp app,
  bool Function() ready,
  String description,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await app.runWithFrames(() async {
      final window = DateTime.now().add(const Duration(seconds: 2));
      while (!ready() && DateTime.now().isBefore(window)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
  }
  expect(ready(), isTrue, reason: 'Timed out waiting for $description.');
}
