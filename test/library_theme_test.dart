import 'dart:convert';
import 'dart:io';
import 'dart:ui' show CheckedState, PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/main.dart';
import 'package:reader/models.dart';
import 'package:reader/reader.dart';
import 'package:reader/text/viewport.dart';
import 'package:reader/theme.dart';

import 'fakes.dart';

/// Stable catalog metadata used to inspect layout without file or cloud imports.
List<CatalogBook> _books({bool longTitles = false, String? cover}) => [
  for (var i = 0; i < 3; i++)
    CatalogBook(
      hash: '${i + 1}' * 63 + 'a',
      fileName: 'book$i.txt',
      path: '/memory/book$i.txt',
      title: longTitles
          ? '中文 العربية हिन्दी A very long multilingual book title number $i'
          : [
              'The Storm of Steel',
              'A Room of One’s Own',
              'The Art of Travel',
            ][i],
      authors: [
        longTitles
            ? 'Long author name 中文 العربية हिन्दी'
            : ['Ernst Jünger', 'Virginia Woolf', 'Alain de Botton'][i],
      ],
      coverPath: cover,
      wordCount: 52430 + i,
      addedAt: DateTime.utc(2026, 1, i + 1),
      lastOpenedAt: i == 0 ? DateTime.utc(2026, 2) : null,
      progress: i == 0 ? .18 : 0,
    ),
];

/// Contrast for small labels and controls, which must remain legible on paper.
double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
}

void main() {
  setUpAll(() async {
    // Use bundled fonts so snapshots represent production typography, not Ahem.
    for (final (family, path) in [
      ('Lora', 'assets/fonts/Lora.ttf'),
      ('DM Sans', 'assets/fonts/DMSans.ttf'),
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(path))).load();
    }
  });
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test(
    'presets share explicit neutral surfaces and accessible text contrast',
    () {
      for (final preset in ReadingTheme.values) {
        final theme = buildReaderTheme(preset);
        final colors = theme.colorScheme;
        expect(theme.scaffoldBackgroundColor, colors.surface);
        expect(colors.surfaceTint, Colors.transparent);
        expect(theme.cardTheme.color, colors.surfaceContainer);
        expect(theme.dialogTheme.backgroundColor, colors.surface);
        expect(theme.bottomSheetTheme.backgroundColor, colors.surface);
        expect(theme.popupMenuTheme.color, colors.surface);
        for (final surface in [colors.surface, colors.surfaceContainer]) {
          expect(
            _contrast(colors.onSurface, surface),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            _contrast(colors.onSurfaceVariant, surface),
            greaterThanOrEqualTo(4.5),
          );
        }
      }
    },
  );

  testWidgets('appearance radios theme open routes and survive restart', (
    tester,
  ) async {
    final preferences = MemorySettingsStore();
    final controller = await testController(
      books: _books(),
      settingsStore: preferences,
    );
    await tester.pumpWidget(ReaderApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Appearance'));
    await tester.pumpAndSettle();
    final selected = tester.widget<RadioMenuButton<ReadingTheme>>(
      find.byWidgetPredicate(
        (w) =>
            w is RadioMenuButton<ReadingTheme> && w.value == ReadingTheme.paper,
      ),
    );
    expect(selected.groupValue, ReadingTheme.paper);
    final semantics = tester.ensureSemantics();
    final radio = find.descendant(
      of: find.widgetWithText(RadioMenuButton<ReadingTheme>, 'Paper'),
      matching: find.byType(Radio<ReadingTheme>),
    );
    expect(
      tester.getSemantics(radio).getSemanticsData().flagsCollection.isChecked,
      CheckedState.isTrue,
    );
    Focus.of(tester.element(find.text('Dark'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.settings.theme, ReadingTheme.dark);
    expect(
      Theme.of(tester.element(find.text('Your library'))).colorScheme,
      buildReaderTheme(ReadingTheme.dark).colorScheme,
    );
    expect(find.text('Paper'), findsNothing);
    await tester.tap(find.byTooltip('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open source licenses'));
    await tester.pumpAndSettle();
    await controller.configure(theme: ReadingTheme.sepia);
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(LicensePage))).colorScheme.surface,
      buildReaderTheme(ReadingTheme.sepia).colorScheme.surface,
    );
    semantics.dispose();
    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
    final restored = await testController(settingsStore: preferences);
    await tester.pumpWidget(ReaderApp(controller: restored));
    await tester.pumpAndSettle();
    expect(restored.settings.theme, ReadingTheme.sepia);
    expect(
      Theme.of(tester.element(find.text('Your library'))).brightness,
      Brightness.light,
    );
    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'reader settings and dialogs share palettes without moving the anchor',
    (tester) async {
      final controller = await testController(books: _books());
      await tester.pumpWidget(ReaderApp(controller: controller));
      await tester.pumpAndSettle();
      final context = tester.element(find.text('Your library'));
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReaderScreen(
            book: controller.books.first,
            controller: controller,
            documentStore: MemoryDocumentStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final viewport = find.byType(TextViewport);
      final navigation = tester.widget<TextViewport>(viewport).navigation;
      final anchor = navigation.leadingPosition;
      final bounds = tester.getRect(viewport);
      await tester.tap(find.byTooltip('Reading settings'));
      await tester.pumpAndSettle();
      for (final (preset, label) in [
        (ReadingTheme.dark, 'Dark'),
        (ReadingTheme.sepia, 'Sepia'),
        (ReadingTheme.paper, 'Paper'),
      ]) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        final expected = buildReaderTheme(preset).colorScheme;
        expect(
          tester.widget<TextViewport>(viewport).background,
          expected.surface,
        );
        expect(
          tester.widget<TextViewport>(viewport).foreground,
          expected.onSurface,
        );
        expect(
          Theme.of(tester.element(find.byTooltip('Close settings')))
              .colorScheme,
          expected,
        );
        expect(navigation.leadingPosition, anchor);
        expect(tester.getRect(viewport), bounds);
      }
      await tester.tap(find.byTooltip('Close settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back to library'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Book actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await controller.configure(theme: ReadingTheme.dark);
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(AlertDialog))).colorScheme.surface,
        buildReaderTheme(ReadingTheme.dark).colorScheme.surface,
      );
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'layouts handle breakpoint resizing and large multilingual metadata',
    (tester) async {
      final controller = await testController(books: _books(longTitles: true));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ReaderApp(controller: controller));
      for (final width in [320.0, 390.0, 699.0, 700.0, 1100.0]) {
        await tester.binding.setSurfaceSize(Size(width, 1000));
        await tester.pumpAndSettle();
        expect(
          find.text('Reader'),
          width >= 700 ? findsOneWidget : findsNothing,
        );
        final cards = find.byType(Card);
        expect(tester.getSize(cards.first).width, lessThanOrEqualTo(480));
        expect(
          tester.getSize(find.byTooltip('Appearance')).width,
          greaterThanOrEqualTo(48),
        );
        expect(tester.takeException(), isNull);
      }
      await tester.binding.setSurfaceSize(const Size(390, 1000));
      // Exercise the app's real MediaQuery without replacing its root state.
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(find.byType(SliverList), findsOneWidget);
      expect(find.byType(SliverGrid), findsNothing);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('local cover art is contained and missing covers fall back', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('reader-cover-test'),
    ))!;
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/cover.png');
    await tester.runAsync(
      () => file.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=',
        ),
      ),
    );
    final controller = await testController(books: _books(cover: file.path));
    await tester.pumpWidget(ReaderApp(controller: controller));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<Image>(find.byType(Image))
          .every((image) => image.fit == BoxFit.contain),
      isTrue,
    );
    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
    final missing = await testController(
      books: _books(cover: '${root.path}/missing.png'),
    );
    await tester.pumpWidget(ReaderApp(controller: missing));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final preset in ReadingTheme.values) {
    for (final compact in [false, true]) {
      testWidgets(
        '${preset.name} ${compact ? 'compact' : 'desktop'} library visual baseline',
        (tester) async {
          debugDefaultTargetPlatformOverride = compact
              ? TargetPlatform.iOS
              : TargetPlatform.macOS;
          await tester.binding.setSurfaceSize(
            compact ? const Size(390, 844) : const Size(1100, 850),
          );
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final controller = await testController(books: _books());
          await controller.configure(theme: preset);
          final key = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: ReaderApp(controller: controller),
            ),
          );
          await tester.pumpAndSettle();
          if (compact) {
            final import = tester.widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton && widget.tooltip == 'Import books',
              ),
            );
            final colors = buildReaderTheme(preset).colorScheme;
            expect(import.color, colors.onPrimary);
            expect(
              _contrast(colors.onPrimary, colors.primary),
              greaterThanOrEqualTo(3),
            );
          }
          await expectLater(
            find.byKey(key),
            matchesGoldenFile(
              'goldens/library_${preset.name}_${compact ? 'compact' : 'desktop'}.png',
            ),
          );
          if (!compact) {
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            try {
              await mouse.addPointer(location: Offset.zero);
              await mouse.moveTo(
                tester.getCenter(find.byType(AspectRatio).first),
              );
              await tester.pumpAndSettle();
              await expectLater(
                find.byKey(key),
                matchesGoldenFile('goldens/library_${preset.name}_hover.png'),
              );
            } finally {
              await mouse.removePointer();
            }
          }
          debugDefaultTargetPlatformOverride = null;
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
