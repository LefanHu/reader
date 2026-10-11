import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/app/reader_controller.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/narration/api.dart';
import 'package:reader/narration/narration_sheet.dart';
import 'package:reader/narration/player.dart';
import 'package:reader/narration/source.dart';
import 'package:reader/narration/store.dart';
import 'package:reader/preferences/reading_theme.dart';
import 'package:reader/preferences/settings_store.dart';
import 'package:reader/settings/settings_screen.dart';
import 'package:reader/text/text_position.dart';
import 'package:reader/theme.dart';

import '../fixtures/catalog_book.dart';
import 'controller_lifecycle.dart';
import 'test_controller.dart';

/// Pumps a minimal app whose 'Open listening' button shows the narration sheet.
///
/// The controller uses real session transactions over offline fakes and is
/// torn down with the widget tree. [settingsButton] adds a 'Settings' button
/// that pushes [SettingsScreen] for shared-preference scenarios.
Future<ReaderController> pumpNarrationHarness(
  WidgetTester tester, {
  required NarrationApi api,
  CatalogBook? book,
  NarrationSource? source,
  NarrationPlayer? player,
  NarrationStore? store,
  SettingsStore? settings,
  TextPosition? start,
  bool settingsButton = false,
  ReadingTheme theme = ReadingTheme.paper,
  double textScale = 1,
}) async {
  final opened = book ?? testBook();
  final controller = await testController(
    books: [opened],
    settingsStore: settings,
    narrationApi: api,
    narrationSource: source,
    narrationPlayer: player,
    narrationStore: store,
    initialize: false,
  );
  addControllerTeardown(tester, controller);
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
          builder: (context) {
            final listen = TextButton(
              onPressed: () =>
                  showNarrationSheet(context, controller, opened, start: start),
              child: const Text('Open listening'),
            );
            if (!settingsButton) return listen;
            return Column(
              children: [
                listen,
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SettingsScreen(controller: controller),
                    ),
                  ),
                  child: const Text('Settings'),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
  return controller;
}
