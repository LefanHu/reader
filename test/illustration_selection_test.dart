import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/illustrations/illustration_selection.dart';
import 'package:reader/illustrations/illustration_setup.dart';
import 'package:reader/preferences/reading_theme.dart';
import 'package:reader/reader/illustration_consent_dialog.dart';
import 'package:reader/theme.dart';

import 'support/fonts.dart';
import 'support/illustration_selection_fixture.dart';

/// Presents a dialog and records its result; `settled` is true once it popped.
class _Result {
  IllustrationSelection? selection;
  bool settled = false;
}

Future<_Result> _open(
  WidgetTester tester,
  IllustrationSetup setup, {
  bool editing = false,
  ReadingTheme theme = ReadingTheme.paper,
  double width = 390,
  double scale = 1,
  TextDirection direction = TextDirection.ltr,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final result = _Result();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildReaderTheme(theme).copyWith(
        platform: width > 700 ? TargetPlatform.macOS : TargetPlatform.iOS,
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: Directionality(
          textDirection: direction,
          child: RepaintBoundary(
            key: const ValueKey('selection-golden'),
            child: child!,
          ),
        ),
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                result.selection = await showDialog<IllustrationSelection>(
                  context: context,
                  builder: (_) => editing
                      ? IllustrationSettingsDialog(setup: setup)
                      : IllustrationConsentDialog(setup: setup),
                );
                result.settled = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

Future<void> _choose(WidgetTester tester, String label) async {
  await tester.tap(
    find.byKey(const ValueKey('illustration-provider-selector')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining(label).last);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadReaderFonts);

  testWidgets('consent defaults to OpenAI and the suggested style', (
    tester,
  ) async {
    final result = await _open(tester, selectionSetup());
    await tester.tap(find.text('Enable illustrations'));
    await tester.pumpAndSettle();
    expect(result.selection?.providerId, 'openai');
    expect(result.selection?.style, 'Watercolor');
  });

  testWidgets('cancel returns no selection', (tester) async {
    final result = await _open(tester, selectionSetup());
    await _choose(tester, 'Google');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result.settled, isTrue);
    expect(result.selection, isNull);
  });

  testWidgets(
    'all seven sources are offered and each selectable one is returned',
    (tester) async {
      for (final (id, label) in const [
        ('openai', 'OpenAI'),
        ('google', 'Google'),
        ('seedream', 'ByteDance'),
        ('qwen', 'Alibaba'),
        ('xai', 'xAI'),
        ('flux', 'BFL'),
        ('diagnostic', 'Pipeline test'),
      ]) {
        final result = await _open(tester, selectionSetup());
        await tester.tap(
          find.byKey(const ValueKey('illustration-provider-selector')),
        );
        await tester.pumpAndSettle();
        for (final other in const [
          'OpenAI',
          'Google',
          'ByteDance',
          'Alibaba',
          'xAI',
          'BFL',
          'Pipeline test',
        ]) {
          expect(find.textContaining(other), findsWidgets, reason: other);
        }
        await tester.tap(find.textContaining(label).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Enable illustrations'));
        await tester.pumpAndSettle();
        expect(result.selection?.providerId, id);
      }
    },
  );

  testWidgets('an unavailable source cannot be chosen', (tester) async {
    final result = await _open(tester, selectionSetup(unavailable: {'qwen'}));
    await _choose(tester, 'Alibaba');
    await tester.tap(find.text('Enable illustrations'));
    await tester.pumpAndSettle();
    expect(result.selection?.providerId, isNot('qwen'));
  });

  testWidgets(
    'without any available source or registration submission is disabled',
    (tester) async {
      await _open(tester, selectionSetup(enabled: false));
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Enable illustrations'),
      );
      expect(button.onPressed, isNull);
    },
  );

  testWidgets(
    'settings open on the saved source and style, and save returns a draft',
    (tester) async {
      final result = await _open(
        tester,
        selectionSetup(savedProvider: 'google'),
        editing: true,
      );
      expect(find.text('Illustration settings'), findsOneWidget);
      expect(find.textContaining('Google'), findsWidgets);
      expect(find.text('Saved custom ink'), findsOneWidget);
      await _choose(tester, 'xAI');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(result.selection?.providerId, 'xai');
      expect(result.selection?.style, 'Saved custom ink');
    },
  );

  for (final theme in ReadingTheme.values) {
    for (final desktop in [false, true]) {
      testWidgets(
        'selection dialog ${theme.name} ${desktop ? 'desktop' : 'compact'} golden',
        (tester) async {
          await _open(
            tester,
            selectionSetup(savedProvider: 'google'),
            editing: true,
            theme: theme,
            width: desktop ? 1100 : 390,
          );
          await expectLater(
            find.byKey(const ValueKey('selection-golden')),
            matchesGoldenFile(
              'goldens/illustration-selection-${theme.name}-${desktop ? 'desktop' : 'compact'}.png',
            ),
          );
        },
      );
    }
  }

  testWidgets('large RTL text keeps the dialog usable and golden stable', (
    tester,
  ) async {
    await _open(
      tester,
      selectionSetup(),
      scale: 2,
      direction: TextDirection.rtl,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Enable illustrations'), findsOneWidget);
    await expectLater(
      find.byKey(const ValueKey('selection-golden')),
      matchesGoldenFile('goldens/illustration-selection-rtl-large.png'),
    );
  });
}
