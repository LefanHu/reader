import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/app/reader_controller.dart';
import 'package:reader/library/library_screen.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/preferences/library_filter.dart';
import 'package:reader/preferences/library_sort.dart';
import 'package:reader/preferences/reading_theme.dart';
import 'package:reader/theme.dart';

import 'support/memory_settings_store.dart';
import 'support/test_controller.dart';

CatalogBook _book({
  bool long = false,
  String? hash,
  String? title,
  double progress = .3,
  DateTime? addedAt,
}) => CatalogBook(
  hash: hash ?? 'a' * 64,
  fileName: 'book.txt',
  path: '/memory/book.txt',
  title:
      title ??
      (long
          ? '中文 العربية हिन्दी A very long multilingual title'
          : 'A Quiet Book'),
  authors: [long ? 'Long author 中文 العربية हिन्दी' : 'A Writer'],
  wordCount: 52430,
  addedAt: addedAt ?? DateTime.utc(2026),
  progress: progress,
);

Future<ReaderController> _mount(
  WidgetTester tester,
  TargetPlatform platform, {
  double width = 1100,
  bool large = false,
  bool reduced = false,
  List<CatalogBook>? books,
  MemorySettingsStore? settingsStore,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = await testController(
    books: books ?? [_book(long: large)],
    settingsStore: settingsStore,
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await controller.flush();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: buildReaderTheme(ReadingTheme.paper).copyWith(platform: platform),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 900),
          textScaler: TextScaler.linear(large ? 2 : 1),
          disableAnimations: reduced,
        ),
        child: LibraryScreen(controller: controller),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets(
    'saved library defaults replace temporary choices without clearing search',
    (tester) async {
      final settingsStore = MemorySettingsStore();
      final controller = await _mount(
        tester,
        TargetPlatform.iOS,
        width: 699,
        settingsStore: settingsStore,
        books: [
          _book(
            hash: 'a' * 64,
            title: 'A Quiet Book',
            progress: .3,
            addedAt: DateTime.utc(2026, 10, 1),
          ),
          _book(
            hash: 'b' * 64,
            title: 'B Quiet Book',
            progress: 1,
            addedAt: DateTime.utc(2026, 10, 2),
          ),
          _book(
            hash: 'c' * 64,
            title: 'C Quiet Book',
            progress: 0,
            addedAt: DateTime.utc(2026, 10, 3),
          ),
        ],
      );

      void expectShelf(List<String> titles) {
        expect(find.byType(SliverList), findsOneWidget);
        expect(find.byType(SliverGrid), findsNothing);
        for (final title in ['A Quiet Book', 'B Quiet Book', 'C Quiet Book']) {
          expect(
            find.text(title),
            titles.contains(title) ? findsOneWidget : findsNothing,
          );
        }
        for (var i = 1; i < titles.length; i++) {
          expect(
            tester.getTopLeft(find.text(titles[i - 1])).dy,
            lessThan(tester.getTopLeft(find.text(titles[i])).dy),
          );
        }
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          'Quiet',
        );
      }

      Future<void> openLibrarySettings() async {
        await tester.tap(find.byTooltip('Settings'));
        await tester.pumpAndSettle();
        final library = find.widgetWithText(ListTile, 'Library');
        await tester.ensureVisible(library);
        await tester.tap(library);
        await tester.pumpAndSettle();
      }

      Future<void> closeSettings() async {
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
      }

      await tester.enterText(find.byType(TextField), 'Quiet');
      await tester.pumpAndSettle();
      expectShelf(['C Quiet Book', 'B Quiet Book', 'A Quiet Book']);
      await tester.tap(find.byType(DropdownButtonFormField<LibraryFilter>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reading').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Sort books'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Title A–Z').last);
      await tester.pumpAndSettle();
      expectShelf(['A Quiet Book']);
      expect(find.text('Title A–Z'), findsOneWidget);
      expect(controller.preferences.settings.libraryFilter, LibraryFilter.all);
      expect(controller.preferences.settings.librarySort, LibrarySort.recent);
      expect(settingsStore.settings.libraryFilter, LibraryFilter.all);
      expect(settingsStore.settings.librarySort, LibrarySort.recent);

      await openLibrarySettings();
      await tester.tap(find.text('Finished'));
      await tester.pumpAndSettle();
      await closeSettings();
      expectShelf(['B Quiet Book']);
      expect(find.text('Title A–Z'), findsOneWidget);
      await controller.flush();
      expect(
        controller.preferences.settings.libraryFilter,
        LibraryFilter.finished,
      );
      expect(settingsStore.settings.libraryFilter, LibraryFilter.finished);
      expect(settingsStore.settings.librarySort, LibrarySort.recent);

      await openLibrarySettings();
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Title'));
      await tester.pumpAndSettle();
      await closeSettings();
      expectShelf(['A Quiet Book', 'B Quiet Book', 'C Quiet Book']);
      expect(find.text('Title A–Z'), findsOneWidget);
      await controller.flush();
      expect(settingsStore.settings.libraryFilter, LibraryFilter.all);
      expect(settingsStore.settings.librarySort, LibrarySort.title);
      expect(controller.preferences.settings.libraryFilter, LibraryFilter.all);
      expect(controller.preferences.settings.librarySort, LibrarySort.title);
    },
  );

  testWidgets(
    'macOS reveal fades without moving covers and stays while a menu is open',
    (tester) async {
      await _mount(tester, TargetPlatform.macOS);
      expect(find.byType(SliverGrid), findsOneWidget);
      final cover = find.byType(AspectRatio).first;
      final bounds = tester.getRect(cover);
      final opacity = find.descendant(
        of: find.byType(AspectRatio).first,
        matching: find.byType(AnimatedOpacity),
      );
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
      final semantics = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(
          RegExp('A Quiet Book.*Approximately 52430 words'),
        ),
        findsOneWidget,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(bounds.center);
      await tester.pump();
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
      await tester.pump(const Duration(milliseconds: 75));
      final fade = tester.widget<FadeTransition>(
        find
            .descendant(of: opacity, matching: find.byType(FadeTransition))
            .first,
      );
      expect(fade.opacity.value, inExclusiveRange(0, 1));
      expect(tester.getRect(cover), bounds);
      await tester.pumpAndSettle();
      expect(find.text('≈ 52,430 words'), findsOneWidget);
      await tester.tap(find.byTooltip('Book actions'));
      await tester.pumpAndSettle();
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete book?'), findsOneWidget);
      semantics.dispose();
      await mouse.removePointer();
    },
  );

  testWidgets(
    'keyboard focus reveals desktop details and reduced motion is immediate',
    (tester) async {
      await _mount(tester, TargetPlatform.macOS, reduced: true);
      final opacity = find.descendant(
        of: find.byType(AspectRatio).first,
        matching: find.byType(AnimatedOpacity),
      );
      expect(tester.widget<AnimatedOpacity>(opacity).duration, Duration.zero);
      // Traverse a complete focus cycle; adding an account control must not make
      // this accessibility proof depend on the toolbar's exact button count.
      final stops = FocusManager.instance.rootScope.traversalDescendants.length;
      for (
        var i = 0;
        i < stops && tester.widget<AnimatedOpacity>(opacity).opacity == 0;
        i++
      ) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
      final cover = tester.getRect(find.byType(AspectRatio).first);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: cover.center);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
    },
  );

  for (final width in [320.0, 699.0, 700.0, 1100.0]) {
    testWidgets(
      'iOS at $width uses a content-sized list with large multilingual text',
      (tester) async {
        await _mount(tester, TargetPlatform.iOS, width: width, large: true);
        expect(find.byType(SliverList), findsOneWidget);
        expect(find.byType(SliverGrid), findsNothing);
        expect(find.text('≈ 52,430 words'), findsOneWidget);
        expect(
          find.text('Reader'),
          width >= 700 ? findsOneWidget : findsNothing,
        );
        expect(
          tester.getSize(find.byTooltip('Book actions')).width,
          greaterThanOrEqualTo(48),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Book actions'));
        await tester.pumpAndSettle();
        expect(find.text('Delete'), findsOneWidget);
      },
    );
  }

  testWidgets('narrow macOS retains cover grids at large text sizes', (
    tester,
  ) async {
    await _mount(tester, TargetPlatform.macOS, width: 390, large: true);
    expect(find.byType(SliverGrid), findsOneWidget);
    expect(find.byType(SliverList), findsNothing);
    final cover = tester.getRect(find.byType(AspectRatio).first);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(cover.center);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
  });
}
