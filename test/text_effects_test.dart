import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/preferences/reader_settings.dart';
import 'package:reader/preferences/reading_theme.dart';
import 'package:reader/text/reader_text_style.dart';
import 'package:reader/text_effects/effect_canvas.dart';
import 'package:reader/text_effects/text_effect_catalog.dart';
import 'package:reader/text_effects/text_effect_detail.dart';
import 'package:reader/text_effects/text_effects_screen.dart';
import 'package:reader/theme.dart';

import 'support/fonts.dart';

const _size = Size(390, 2400);

Widget _app(Widget home, {ReadingTheme theme = ReadingTheme.paper}) =>
    MaterialApp(theme: buildReaderTheme(theme), home: home);

Future<void> _gallery(
  WidgetTester tester, {
  ReadingTheme theme = ReadingTheme.paper,
  bool reduceMotion = false,
}) async {
  // Tall enough that every tile builds and paints at once.
  await tester.binding.setSurfaceSize(_size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _app(
      MediaQuery(
        data: MediaQueryData(size: _size, disableAnimations: reduceMotion),
        child: TextEffectsScreen(settings: ReaderSettings(theme: theme)),
      ),
      theme: theme,
    ),
  );
}

Future<void> _detail(WidgetTester tester, int index) async {
  await tester.binding.setSurfaceSize(_size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _app(
      TextEffectDetail(
        initialIndex: index,
        style: readerTextStyle(const ReaderSettings(), Colors.black),
      ),
    ),
  );
}

Future<void> _run(WidgetTester tester, Duration duration) async {
  const step = Duration(milliseconds: 100);
  for (var t = Duration.zero; t < duration; t += step) {
    await tester.pump(step);
  }
}

void main() {
  setUpAll(loadReaderFonts);

  test('every anchor occurs in its passage', () {
    for (final entry in textEffects) {
      expect(entry.passage.text, contains(entry.passage.anchor));
    }
  });

  for (final theme in ReadingTheme.values) {
    testWidgets('every gallery tile animates without errors on ${theme.name}', (
      tester,
    ) async {
      await _gallery(tester, theme: theme);
      expect(find.byType(EffectCanvas), findsNWidgets(textEffects.length));
      // Covers several narration loops and hint cycles.
      await _run(tester, const Duration(seconds: 8));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a gallery tile opens its effect and pages to the next', (
    tester,
  ) async {
    await _gallery(tester);
    await tester.tap(find.text('Pencil hatching'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(TextEffectDetail), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Pencil hatching'), findsOneWidget);
    await tester.tap(find.byTooltip('Next effect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.widgetWithText(AppBar, 'Ink drop'), findsOneWidget);
  });

  for (final (index, entry) in textEffects.indexed) {
    testWidgets('${entry.name} runs its full response without errors', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _detail(tester, index);
      final passage = find.bySemanticsLabel(entry.passage.text);
      if (!entry.narration) {
        expect(tester.getSemantics(passage), isSemantics(isSelected: false));
        await tester.tap(passage);
      }
      await _run(tester, entry.activation + const Duration(seconds: 3));
      if (!entry.narration) {
        expect(tester.getSemantics(passage), isSemantics(isSelected: true));
        await tester.tap(passage);
        await _run(tester, const Duration(seconds: 1));
        expect(tester.getSemantics(passage), isSemantics(isSelected: false));
      }
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets('pausing narration stops its clock', (tester) async {
    await _detail(tester, illustrationEffects.length);
    await tester.tap(find.text('Pause narration'));
    await _run(tester, const Duration(seconds: 1));
    expect(find.text('Play narration'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.tap(find.text('Play narration'));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('reduced motion paints still tiles', (tester) async {
    await _gallery(tester, reduceMotion: true);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });
}
