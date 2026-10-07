import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/controller.dart';
import 'package:reader/models.dart';
import 'package:reader/reader.dart';
import 'package:reader/text/document.dart' as text;
import 'package:reader/text/viewport.dart';

import 'fakes.dart';

/// Real reader shell with enough text to observe scrolling and page positions.
Future<ReaderController> _mount(
  WidgetTester tester, {
  ReadingMode mode = ReadingMode.scroll,
  bool reducedMotion = false,
}) async {
  final book = testBook();
  final controller = await testController(books: [book]);
  addTearDown(controller.dispose);
  await controller.configure(mode: mode);
  final store = MemoryDocumentStore(
    sections: [
      text.TextSection(
        id: 's0',
        blocks: [
          text.TextBlock(
            id: 'p0',
            text: 'English 中文 العربية हिन्दी e\u0301 👩🏽‍🚀 ' * 100,
          ),
        ],
      ),
    ],
  );
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
        child: child!,
      ),
      home: ReaderScreen(
        book: book,
        controller: controller,
        documentStore: store,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

FadeTransition _toolbarFade(WidgetTester tester) =>
    tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byTooltip('Hide reading controls'),
            matching: find.byType(FadeTransition),
          )
          .first,
    );

/// Material exposes button descriptions as tooltips on some platform themes.
bool _hasControlSemantics(WidgetTester tester, String description) {
  var found = false;
  void visit(SemanticsNode node) {
    final data = node.getSemanticsData();
    if (data.tooltip == description || data.label == description) found = true;
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester.getSemantics(find.byType(ReaderScreen)));
  return found;
}

void main() {
  testWidgets('toolbar chapter title is centered on the reading viewport', (
    tester,
  ) async {
    await _mount(tester);
    final title = find.text('Section 1');
    final viewport = find.byType(TextViewport);
    for (final width in [390.0, 599.0, 600.0, 800.0, 1354.0]) {
      await tester.binding.setSurfaceSize(Size(width, 900));
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(title).dx,
        closeTo(tester.getCenter(viewport).dx, .01),
      );
      expect(find.byTooltip('Choose chapter'), findsOneWidget);
      expect(find.byTooltip('AI illustrations'), findsOneWidget);
      expect(find.byTooltip('Hide reading controls'), findsOneWidget);
      final chapter = tester.getRect(find.byTooltip('Choose chapter'));
      expect(tester.getRect(title).right, lessThanOrEqualTo(chapter.left));
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
    'reading settings keep button bounds without selection checkmarks',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final controller = await _mount(tester);
      await tester.tap(find.byTooltip('Reading settings'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SegmentedButton<ReadingMode>>(
              find.byType(SegmentedButton<ReadingMode>),
            )
            .showSelectedIcon,
        isFalse,
      );
      expect(
        tester
            .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
            .showSelectedIcon,
        isFalse,
      );
      expect(
        tester
            .widget<SegmentedButton<ReadingTheme>>(
              find.byType(SegmentedButton<ReadingTheme>),
            )
            .showSelectedIcon,
        isFalse,
      );
      for (final labels in [
        ['Pages', 'Page flip', 'Scroll'],
        ['Serif', 'Sans serif'],
        ['Paper', 'Sepia', 'Dark'],
      ]) {
        await tester.ensureVisible(find.text(labels.first));
        await tester.pumpAndSettle();
        Rect buttonRect(String label) => tester.getRect(
          find
              .ancestor(of: find.text(label), matching: find.byType(TextButton))
              .first,
        );
        final bounds = {for (final label in labels) label: buttonRect(label)};
        for (final label in labels) {
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          for (final entry in bounds.entries) {
            expect(buttonRect(entry.key), entry.value);
          }
          final node = tester.getSemantics(
            find
                .ancestor(
                  of: find.text(label),
                  matching: find.byType(TextButton),
                )
                .first,
          );
          expect(
            node.getSemanticsData().flagsCollection.isSelected,
            Tristate.isTrue,
          );
        }
      }
      expect(controller.settings.mode, ReadingMode.scroll);
      expect(controller.settings.serif, isFalse);
      expect(controller.settings.theme, ReadingTheme.dark);
      expect(find.byIcon(Icons.check), findsNothing);
      semantics.dispose();
    },
  );

  for (final mode in ReadingMode.values) {
    testWidgets(
      '${mode.name} controls animate without moving text or changing position',
      (tester) async {
        final controller = await _mount(tester, mode: mode);
        final navigation = tester
            .widget<TextViewport>(find.byType(TextViewport))
            .navigation;
        navigation.next();
        await tester.pumpAndSettle();
        final viewport = tester.getRect(find.byType(TextViewport));
        final paints = find.descendant(
          of: find.byType(TextViewport),
          matching: find.byType(CustomPaint),
        );
        final textRect = tester.getRect(paints.first);
        final anchor = navigation.leadingPosition;
        final toolbarTop = tester
            .getTopLeft(find.byTooltip('Hide reading controls'))
            .dy;
        final nextTooltip = mode == ReadingMode.scroll
            ? 'Next screen'
            : 'Next page';
        final navigationTop = tester.getTopLeft(find.byTooltip(nextTooltip)).dy;
        final scrollable = find.descendant(
          of: find.byType(TextViewport),
          matching: find.byType(Scrollable),
        );
        double? scrollOffset() => mode == ReadingMode.scroll
            ? tester.state<ScrollableState>(scrollable.first).position.pixels
            : null;
        final offset = scrollOffset();
        void unchanged() {
          expect(tester.getRect(find.byType(TextViewport)), viewport);
          expect(tester.getRect(paints.first), textRect);
          expect(navigation.leadingPosition, anchor);
          expect(controller.books.single.lastPosition, anchor);
          expect(scrollOffset(), offset);
        }

        await tester.tapAt(viewport.center);
        await tester.pump();
        unchanged();
        await tester.pump(const Duration(milliseconds: 80));
        expect(_toolbarFade(tester).opacity.value, inExclusiveRange(0, 1));
        expect(
          tester.getTopLeft(find.byTooltip('Hide reading controls')).dy,
          lessThan(toolbarTop),
        );
        expect(
          tester.getTopLeft(find.byTooltip(nextTooltip)).dy,
          greaterThan(navigationTop),
        );
        unchanged();
        await tester.pumpAndSettle();
        expect(_toolbarFade(tester).opacity.value, 0);
        unchanged();
        await tester.tap(find.byTooltip('Show reading controls'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(_toolbarFade(tester).opacity.value, inExclusiveRange(0, 1));
        unchanged();
        await tester.pumpAndSettle();
        expect(_toolbarFade(tester).opacity.value, 1);
        unchanged();
      },
    );
  }

  testWidgets(
    'hidden controls immediately exclude taps focus and accessibility',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await _mount(tester, mode: ReadingMode.pages);
      final viewport = tester.getRect(find.byType(TextViewport));
      final navigation = tester
          .widget<TextViewport>(find.byType(TextViewport))
          .navigation;
      final anchor = navigation.leadingPosition;
      final settingsPoint = tester.getCenter(
        find.byTooltip('Reading settings'),
      );
      final nextPoint = tester.getCenter(find.byTooltip('Next page'));
      final focus = Focus.of(
        tester.element(
          find
              .descendant(
                of: find.byTooltip('Reading settings'),
                matching: find.byType(Icon),
              )
              .first,
        ),
      );
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      expect(_hasControlSemantics(tester, 'Reading settings'), isTrue);
      await tester.tapAt(viewport.center);
      await tester.pump();
      expect(_hasControlSemantics(tester, 'Reading settings'), isFalse);
      expect(_hasControlSemantics(tester, 'Next page'), isFalse);
      expect(focus.hasFocus, isFalse);
      expect(focus.canRequestFocus, isFalse);
      focus.requestFocus();
      await tester.tapAt(settingsPoint);
      await tester.tapAt(nextPoint);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close settings'), findsNothing);
      expect(navigation.leadingPosition, anchor);
      expect(focus.hasFocus, isFalse);
      expect(_hasControlSemantics(tester, 'Show reading controls'), isTrue);
      await tester.tap(find.byTooltip('Show reading controls'));
      await tester.pumpAndSettle();
      expect(_hasControlSemantics(tester, 'Reading settings'), isTrue);
      expect(focus.canRequestFocus, isTrue);
      semantics.dispose();
    },
  );

  testWidgets(
    'repeated center taps reverse the control fade from its current value',
    (tester) async {
      await _mount(tester);
      final viewport = tester.getRect(find.byType(TextViewport));
      await tester.tapAt(viewport.center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final fading = _toolbarFade(tester).opacity.value;
      expect(fading, inExclusiveRange(0, 1));
      await tester.tapAt(viewport.center);
      await tester.pump();
      expect(_toolbarFade(tester).opacity.value, closeTo(fading, .0001));
      await tester.pump(const Duration(milliseconds: 80));
      expect(_toolbarFade(tester).opacity.value, greaterThan(fading));
      expect(tester.getRect(find.byType(TextViewport)), viewport);
      await tester.pumpAndSettle();
      expect(_toolbarFade(tester).opacity.value, 1);
    },
  );

  testWidgets(
    'reduced motion switches control visibility instantly with fixed text bounds',
    (tester) async {
      await _mount(tester, reducedMotion: true);
      final viewport = tester.getRect(find.byType(TextViewport));
      await tester.tap(find.byTooltip('Hide reading controls'));
      await tester.pump();
      expect(_toolbarFade(tester).opacity.value, 0);
      expect(tester.getRect(find.byType(TextViewport)), viewport);
      await tester.tap(find.byTooltip('Show reading controls'));
      await tester.pump();
      expect(_toolbarFade(tester).opacity.value, 1);
      expect(tester.getRect(find.byType(TextViewport)), viewport);
    },
  );
}
