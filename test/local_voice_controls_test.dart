import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/app/reader_controller.dart';
import 'package:reader/importing/book_importer.dart';
import 'package:reader/narration/narration_sheet.dart';
import 'package:reader/preferences/reader_settings.dart';
import 'package:reader/preferences/reading_theme.dart';
import 'package:reader/settings/settings_screen.dart';
import 'package:reader/theme.dart';

import 'fixtures/catalog_book.dart';
import 'support/controller_lifecycle.dart';
import 'support/fake_illustration_api.dart';
import 'support/fake_narration_api.dart';
import 'support/fake_narration_player.dart';
import 'support/fake_picker.dart';
import 'support/fake_word_counter.dart';
import 'support/fixture_local_narration_source.dart';
import 'support/memory_catalog_store.dart';
import 'support/memory_document_store.dart';
import 'support/memory_illustration_store.dart';
import 'support/memory_narration_store.dart';
import 'support/memory_settings_store.dart';

void main() {
  testWidgets(
    'installed voice choice is shared by Settings and local listening',
    (tester) async {
      final source = FixtureLocalNarrationSource();
      final settings = MemorySettingsStore();
      final api = _UsageCountingApi();
      final player = FakeNarrationPlayer();
      final controller = await _mount(
        tester,
        source: source,
        settings: settings,
        api: api,
        player: player,
      );
      expect(settings.settings.narrationVoice, source.defaultVoice);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Narration'));
      await tester.pumpAndSettle();
      expect(find.text('en-US · Enhanced'), findsOneWidget);
      expect(find.text('en-GB · Premium'), findsOneWidget);
      await tester.tap(find.text(source.voices.last.name));
      await tester.pumpAndSettle();
      expect(settings.settings.narrationVoice, source.voices.last.identifier);
      expect(source.renders, 0);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open listening'));
      await tester.pumpAndSettle();
      expect(find.text('On-device narration'), findsOneWidget);
      expect(find.byTooltip('Cloud account'), findsNothing);
      expect(find.text('Refresh allowance'), findsNothing);
      expect(
        find.textContaining('Speech is generated on this device'),
        findsOneWidget,
      );
      final voiceControl = find.descendant(
        of: find.byType(DropdownButtonFormField<String>).first,
        matching: find.byIcon(Icons.arrow_drop_down),
      );
      await tester.ensureVisible(voiceControl);
      await tester.pumpAndSettle();
      expect(voiceControl.hitTestable(), findsOneWidget);
      await tester.tap(voiceControl);
      await tester.pumpAndSettle();
      await tester.tap(find.text(source.voices.first.name).last);
      await tester.pumpAndSettle();
      expect(settings.settings.narrationVoice, source.voices.first.identifier);
      expect(source.renders, 0);
      await tester.ensureVisible(
        find.byKey(const ValueKey('narration-transport')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('narration-transport')));
      await tester.pumpAndSettle();
      expect(player.playing, isTrue);
      expect(api.registrations, 0);
      expect(api.requests, isEmpty);
      expect(api.usageRequests, 0);
      await controller.narration!.pause();
      await tester.pumpAndSettle();
      await _closeListening(tester);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Narration'));
      await tester.pumpAndSettle();
      final tile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, source.voices.first.name),
      );
      expect(tile.selected, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final theme in ReadingTheme.values) {
    testWidgets(
      'missing local voice stays honest at large text on ${theme.name}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        const unavailable = 'apple:fixture.removed';
        final settings = MemorySettingsStore(
          const ReaderSettings(narrationVoice: unavailable),
        );
        final source = FixtureLocalNarrationSource();
        final player = FakeNarrationPlayer();
        final controller = await _mount(
          tester,
          source: source,
          settings: settings,
          api: _UsageCountingApi(),
          player: player,
          theme: theme,
          textScale: 2.2,
        );
        final bookPosition = controller.catalog.books.single.lastPosition;
        // A restored missing voice must not reject edits before book attachment.
        await controller.preferences.configure(
          theme: theme,
          narrationSpeed: 1.5,
        );
        expect(player.multiplier, 1.5);
        expect(settings.settings.narrationVoice, unavailable);
        expect(settings.settings.narrationSpeed, 1.5);
        await tester.tap(find.text('Open listening'));
        await tester.pumpAndSettle();
        // At large text the helper caption can contain the field's center.
        final voiceControl = find.descendant(
          of: find.byType(DropdownButtonFormField<String>).first,
          matching: find.byIcon(Icons.arrow_drop_down),
        );
        await tester.ensureVisible(voiceControl);
        await tester.pumpAndSettle();
        expect(find.text('Unavailable: $unavailable'), findsOneWidget);
        expect(settings.settings.narrationVoice, unavailable);
        expect(tester.takeException(), isNull);
        expect(voiceControl.hitTestable(), findsOneWidget);
        await tester.tap(voiceControl);
        await tester.pumpAndSettle();
        final installedChoice = find.text(source.voices.last.name);
        // Dropdown entries are lazy when large labels extend below the menu.
        await tester.scrollUntilVisible(
          installedChoice,
          100,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        expect(installedChoice.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(installedChoice, findsNothing);
        await tester.ensureVisible(
          find.byKey(const ValueKey('narration-transport')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('narration-transport')));
        await tester.pumpAndSettle();
        expect(player.playing, isFalse);
        final retry = find.byKey(const ValueKey('narration-retry'));
        await tester.ensureVisible(retry);
        await tester.pumpAndSettle();
        await tester.tap(retry);
        await tester.pumpAndSettle();
        // Retrying an unavailable selection must not substitute another voice.
        expect(player.playing, isFalse);
        expect(controller.catalog.books.single.lastPosition, bookPosition);
        expect(settings.settings.narrationVoice, unavailable);
        await tester.ensureVisible(find.text('Clear narration audio'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _closeListening(tester);
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Narration'),
          100,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Narration'));
        await tester.pumpAndSettle();
        expect(find.text('Unavailable: $unavailable'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await controller.preferences.reset();
        await tester.pumpAndSettle();
        expect(settings.settings.narrationVoice, source.defaultVoice);
        expect(find.text('Unavailable: $unavailable'), findsNothing);
        expect(source.renders, 0);
      },
    );
  }
}

Future<void> _closeListening(WidgetTester tester) async {
  final close = find.byTooltip('Close listening controls');
  await tester.ensureVisible(close);
  await tester.pumpAndSettle();
  expect(close.hitTestable(), findsOneWidget);
  await tester.tap(close);
  await tester.pumpAndSettle();
  expect(find.byType(NarrationSheet), findsNothing);
}

Future<ReaderController> _mount(
  WidgetTester tester, {
  required FixtureLocalNarrationSource source,
  required MemorySettingsStore settings,
  required _UsageCountingApi api,
  required FakeNarrationPlayer player,
  ReadingTheme theme = ReadingTheme.paper,
  double textScale = 1,
}) async {
  final book = testBook();
  final controller = ReaderController(
    catalogStore: MemoryCatalogStore([book]),
    settingsStore: settings,
    importer: BookImporter(root: Directory.systemTemp),
    picker: FakePicker([]),
    illustrationApi: FakeIllustrationApi(),
    illustrationStore: MemoryIllustrationStore(),
    wordCounter: FakeWordCounter(),
    narrationApi: api,
    narrationSource: source,
    narrationPlayer: player,
    narrationStore: MemoryNarrationStore(),
    narrationDocuments: MemoryDocumentStore(),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await disposeControllerWithFrames(tester, controller);
  });
  await controller.initialize();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildReaderTheme(theme),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Column(
            children: [
              TextButton(
                onPressed: () => showNarrationSheet(context, controller, book),
                child: const Text('Open listening'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsScreen(controller: controller),
                  ),
                ),
                child: const Text('Settings'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return controller;
}

class _UsageCountingApi extends FakeNarrationApi {
  int usageRequests = 0;

  @override
  Future<Map<String, dynamic>> configuration() async {
    usageRequests++;
    return super.configuration();
  }
}
