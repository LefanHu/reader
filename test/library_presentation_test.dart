import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/library.dart';
import 'package:reader/models.dart';
import 'package:reader/theme.dart';

import 'fakes.dart';

CatalogBook _book({bool long = false}) => CatalogBook(
  hash: 'a' * 64,
  fileName: 'book.txt',
  path: '/memory/book.txt',
  title: long
      ? '中文 العربية हिन्दी A very long multilingual title'
      : 'A Quiet Book',
  authors: [long ? 'Long author 中文 العربية हिन्दी' : 'A Writer'],
  wordCount: 52430,
  addedAt: DateTime.utc(2026),
  progress: .3,
);

Future<void> _mount(
  WidgetTester tester,
  TargetPlatform platform, {
  double width = 1100,
  bool large = false,
  bool reduced = false,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = await testController(books: [_book(long: large)]);
  addTearDown(controller.dispose);
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
}

void main() {
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
      for (
        var i = 0;
        i < 8 && tester.widget<AnimatedOpacity>(opacity).opacity == 0;
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
