import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/models.dart';
import 'package:reader/text/document.dart';
import 'package:reader/theme.dart';

import '../support/native_test_app.dart';

/// Registers independent offline import and application appearance scenarios.
void registerLibraryTests() {
  testWidgets('imports EPUB and TXT through the library action', (
    tester,
  ) async {
    final app = await NativeTestApp.launch(tester, importBooks: false);
    await tester.tap(find.text('Import books').first);
    await tester.pumpAndSettle();
    expect(app.controller.books, hasLength(2));
    expect(find.text('Import results'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    for (final title in ['Unicode Test', 'Novel']) {
      final book = app.book(title);
      expect(await File(book.path).exists(), isTrue);
      final document = await TextDocumentStore().load(book.path);
      expect(document.title, title);
      expect(document.sections, isNotEmpty);
    }
  });

  for (final preset in ReadingTheme.values) {
    testWidgets(
      'appearance menu applies ${preset.name} throughout the library',
      (tester) async {
        final app = await NativeTestApp.launch(tester);
        await tester.tap(find.byTooltip('Appearance'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(themeLabel(preset)));
        await tester.pumpAndSettle();
        expect(app.controller.settings.theme, preset);
        expect(
          Theme.of(tester.element(find.text('Your library'))).colorScheme,
          buildReaderTheme(preset).colorScheme,
        );
        await app.capture('library-${preset.name}');
      },
    );
  }
}
