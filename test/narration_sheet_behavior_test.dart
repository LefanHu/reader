import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/app/reader_controller.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/narration/narration_manifest.dart';
import 'package:reader/narration/narration_registration.dart';
import 'package:reader/narration/narration_sheet.dart';
import 'package:reader/preferences/reading_theme.dart';
import 'package:reader/text/text_position.dart';
import 'package:reader/theme.dart';

import 'fixtures/catalog_book.dart';
import 'support/fake_narration_api.dart';
import 'support/fake_narration_player.dart';
import 'support/memory_narration_store.dart';
import 'support/memory_settings_store.dart';
import 'support/narration_harness.dart';

const _committed = TextPosition(sectionId: 's0', blockId: 'p0', offset: 4);
const _selected = TextPosition(sectionId: 's0', blockId: 'p1');
const _loading = ValueKey('narration-loading');
const _transport = ValueKey('narration-transport');
const _retry = ValueKey('narration-retry');

void main() {
  testWidgets('sheet is visible throughout attachment and registration', (
    tester,
  ) async {
    final api = FakeNarrationApi()
      ..registrationGate = Completer<NarrationRegistration>();
    final store = _GatedNarrationStore();
    final controller = await _mount(tester, api: api, store: store);

    await tester.tap(find.text('Open listening'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(NarrationSheet), findsOneWidget);
    expect(find.text('Test Book'), findsOneWidget);
    expect(find.text('Test Author'), findsOneWidget);
    expect(find.byKey(_loading), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(_transport)).onPressed,
      isNull,
    );

    store.loaded.complete();
    await tester.pump();
    expect(find.byKey(_loading), findsOneWidget);
    expect(api.registrations, 1);
    api.registrationGate!.complete(
      const NarrationRegistration('account', 'cloud-book', 500000),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(_loading), findsNothing);
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
    expect(api.requests, isEmpty);
    expect(controller.catalog.books.single.lastPosition, _committed);
  });

  testWidgets('registration errors stay visible and Retry preserves reading', (
    tester,
  ) async {
    final api = FakeNarrationApi()
      ..registrationGate = Completer<NarrationRegistration>();
    final controller = await _mount(tester, api: api);
    await tester.tap(find.text('Open listening'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    api.registrationGate!.completeError(StateError('Offline registration'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Offline registration'), findsOneWidget);
    expect(find.byKey(_retry), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(controller.catalog.books.single.lastPosition, _committed);
    expect(controller.catalog.books.single.progress, .2);

    api.registrationGate = null;
    await tester.tap(find.byKey(_retry));
    await tester.pumpAndSettle();
    expect(api.registrations, 2);
    expect(find.textContaining('Offline registration'), findsNothing);
    expect(find.text('Play'), findsOneWidget);
    expect(api.requests, isEmpty);
    await tester.tap(find.byTooltip('Close listening controls'));
    await tester.pumpAndSettle();
    expect(find.text('Open listening'), findsOneWidget);
    expect(controller.catalog.books.single.lastPosition, _committed);
  });

  testWidgets(
    'selected playback shows buffering and retries without committing; settings are global',
    (tester) async {
      final api = FakeNarrationApi()..gate = Completer<Uint8List>();
      final player = FakeNarrationPlayer();
      final settings = MemorySettingsStore();
      final controller = await _mount(
        tester,
        api: api,
        player: player,
        settings: settings,
        start: _selected,
      );
      await tester.tap(find.text('Open listening'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Loading audio…'), findsOneWidget);
      expect(find.byKey(_loading), findsOneWidget);
      expect(find.text('Pause'), findsOneWidget);
      expect(api.requests.single.start, _selected);
      expect(controller.catalog.books.single.lastPosition, _committed);

      api.gate!.completeError(StateError('Audio temporarily unavailable'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Audio temporarily unavailable'),
        findsOneWidget,
      );
      expect(find.byKey(_retry), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
      api.gate = null;
      await tester.tap(find.byKey(_retry));
      await tester.pumpAndSettle();
      expect(player.playing, isTrue);
      expect(find.text('Listening'), findsOneWidget);
      expect(find.text('Pause'), findsOneWidget);
      expect(controller.narration!.manifest.chunkStart, _selected);
      expect(controller.catalog.books.single.lastPosition, _committed);
      expect(controller.catalog.books.single.progress, .2);

      await tester.ensureVisible(find.byTooltip('Forward 15 seconds'));
      await tester.tap(find.byTooltip('Forward 15 seconds'));
      await tester.pumpAndSettle();
      expect(player.position, const Duration(seconds: 15));
      expect(controller.catalog.books.single.lastPosition, _committed);
      await tester.ensureVisible(find.byKey(_transport));
      await tester.tap(find.byKey(_transport));
      await tester.pumpAndSettle();
      expect(find.text('Paused'), findsOneWidget);
      expect(player.playing, isFalse);

      final requests = api.requests.length;
      await tester.ensureVisible(
        find.byType(DropdownButtonFormField<String>).first,
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cedar').last);
      await tester.pumpAndSettle();
      expect(settings.settings.narrationVoice, 'cedar');
      expect(controller.narration!.manifest.voice, 'cedar');
      expect(controller.narration!.manifest.offsetMs, 0);
      expect(controller.narration!.manifest.chunkId, isNull);

      await tester.ensureVisible(find.byType(DropdownButtonFormField<double>));
      await tester.tap(find.byType(DropdownButtonFormField<double>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5×').last);
      await tester.pumpAndSettle();
      expect(settings.settings.narrationSpeed, 1.5);
      expect(player.multiplier, 1.5);
      expect(api.requests.length, requests);
      expect(controller.catalog.books.single.lastPosition, _committed);
    },
  );

  for (final preset in ReadingTheme.values) {
    testWidgets(
      'narrow ${preset.name} sheet accommodates large text and errors',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final api = FakeNarrationApi()..offline = true;
        await _mount(tester, api: api, theme: preset, textScale: 2.2);
        await tester.tap(find.text('Open listening'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byKey(_transport));
        await tester.tap(find.byKey(_transport));
        await tester.pumpAndSettle();
        expect(find.textContaining('Offline'), findsOneWidget);
        await tester.ensureVisible(find.byKey(_retry));
        expect(tester.takeException(), isNull);
        final status = tester.widget<Container>(
          find.byKey(const ValueKey('narration-status')),
        );
        final scheme = buildReaderTheme(preset).colorScheme;
        expect(
          (status.decoration! as BoxDecoration).color,
          scheme.errorContainer,
        );
        await tester.ensureVisible(find.text('Clear downloaded audio'));
        expect(tester.takeException(), isNull);
      },
    );
  }
}

/// Each sheet test uses real controller/session transactions and offline fakes.
Future<ReaderController> _mount(
  WidgetTester tester, {
  required FakeNarrationApi api,
  FakeNarrationPlayer? player,
  MemoryNarrationStore? store,
  MemorySettingsStore? settings,
  TextPosition? start,
  ReadingTheme theme = ReadingTheme.paper,
  double textScale = 1,
}) => pumpNarrationHarness(
  tester,
  api: api,
  book: testBook(position: _committed, progress: .2),
  player: player,
  store: store,
  settings: settings,
  start: start,
  theme: theme,
  textScale: textScale,
);

/// Delays local attachment independently of cloud authentication/registration.
class _GatedNarrationStore extends MemoryNarrationStore {
  final loaded = Completer<void>();

  @override
  Future<NarrationManifest> load(CatalogBook book) async {
    await loaded.future;
    return super.load(book);
  }
}
