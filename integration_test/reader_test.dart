import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reader/book_service.dart';
import 'package:reader/controller.dart';
import 'package:reader/main.dart';
import 'package:reader/models.dart';
import 'package:reader/storage.dart';
import 'package:reader/text/document.dart';
import 'package:reader/text/viewport.dart';

import '../test/fakes.dart';
import '../test/text_parser_test.dart' show epubFixture;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native EPUB and TXT import reading reflow resume and semantics', (
    tester,
  ) async {
    // Use an isolated app-owned temporary catalog, never the reader's real shelf.
    final root = await Directory.systemTemp.createTemp('reader_native_test');
    final prose = List.generate(
      120,
      (i) => 'Paragraph $i: 中文 العربية שָׁלוֹם हिन्दी ไทย e\u0301 👩🏽‍🚀.',
    ).join('\n\n');
    final txt = Uint8List.fromList(utf8.encode(prose));
    final epub = epubFixture();
    final store = FileCatalogStore(root);
    final controller = ReaderController(
      catalogStore: store,
      settingsStore: MemorySettingsStore(),
      importer: BookImporter(root: root),
      picker: FakePicker([
        ImportCandidate(
          name: 'Unicode Test.txt',
          size: txt.length,
          readBytes: () async => txt,
        ),
        ImportCandidate(
          name: 'Native.epub',
          size: epub.length,
          readBytes: () async => epub,
        ),
      ]),
      illustrationApi: FakeIllustrationApi(),
    );
    await controller.initialize();
    final screenshotKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: screenshotKey,
        child: ReaderApp(controller: controller),
      ),
    );
    await tester.tap(find.text('Import books').first);
    await tester.pumpAndSettle();
    expect(controller.books, hasLength(2));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Unicode Test').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unicode Test').last);
    await tester.pumpAndSettle();
    final viewport = tester.widget<TextViewport>(find.byType(TextViewport));
    viewport.navigation.next();
    await tester.pumpAndSettle();
    final anchor = viewport.navigation.leadingPosition!;
    expect(anchor.blockId, isNot(''));
    final docStore = TextDocumentStore();
    final book = controller.books.firstWhere((b) => b.title == 'Unicode Test');
    final section = await docStore.loadSection(book.path, anchor.sectionId);
    expect(
      graphemeFloor(
        section.blocks.firstWhere((b) => b.id == anchor.blockId).text,
        anchor.offset,
      ),
      anchor.offset,
    );
    await controller.configure(
      mode: ReadingMode.pageFlip,
      fontSize: 140,
      serif: false,
      theme: ReadingTheme.sepia,
    );
    await tester.pumpAndSettle();
    expect(viewport.navigation.leadingPosition, anchor);
    // Hold an interactive curl while capturing real platform rendering.
    final viewportRect = tester.getRect(find.byType(TextViewport));
    final drag = await tester.startGesture(viewportRect.center);
    await drag.moveBy(const Offset(-20, 0));
    await tester.pump();
    await drag.moveBy(Offset(-viewportRect.width * .28, 0));
    await tester.pump(const Duration(milliseconds: 200));
    expect(viewport.navigation.leadingPosition, anchor);
    expect(viewport.navigation.retainedTextureCount, 2);
    final image =
        await (screenshotKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
    final pixels = await image.toByteData(format: ui.ImageByteFormat.png);
    final screenshot = File(
      '${Directory.systemTemp.path}/reader-native-${Platform.operatingSystem}.png',
    );
    await screenshot.writeAsBytes(pixels!.buffer.asUint8List());
    image.dispose();
    debugPrint('Reader native screenshot: ${screenshot.path}');
    await drag.cancel();
    await tester.pumpAndSettle();
    expect(viewport.navigation.leadingPosition, anchor);
    expect(viewport.navigation.retainedTextureCount, 0);
    for (final mode in ReadingMode.values) {
      await controller.configure(mode: mode);
      await tester.pump();
      final initialPaints = find.descendant(
        of: find.byType(TextViewport),
        matching: find.byWidgetPredicate(
          (widget) => widget is CustomPaint && widget.painter != null,
        ),
      );
      final firstFrameText = tester.getRect(initialPaints.first);
      await tester.pumpAndSettle();
      expect(tester.getRect(initialPaints.first), firstFrameText);
      expect(viewport.navigation.leadingPosition, anchor);
      final chapterTitle = tester
          .widget<TextViewport>(find.byType(TextViewport))
          .document
          .sections
          .first
          .title;
      expect(
        tester.getCenter(find.text(chapterTitle)).dx,
        closeTo(tester.getCenter(find.byType(TextViewport)).dx, .01),
      );
      final stationaryViewport = tester.getRect(find.byType(TextViewport));
      final textPaints = find.descendant(
        of: find.byType(TextViewport),
        matching: find.byWidgetPredicate(
          (widget) => widget is CustomPaint && widget.painter != null,
        ),
      );
      final stationaryText = tester.getRect(textPaints.first);
      await tester.tapAt(stationaryViewport.center);
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getRect(find.byType(TextViewport)), stationaryViewport);
      expect(tester.getRect(textPaints.first), stationaryText);
      expect(viewport.navigation.leadingPosition, anchor);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Show reading controls'), findsOneWidget);
      expect(tester.getRect(find.byType(TextViewport)), stationaryViewport);
      await tester.tap(find.byTooltip('Show reading controls'));
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getRect(find.byType(TextViewport)), stationaryViewport);
      expect(tester.getRect(textPaints.first), stationaryText);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(TextViewport)), stationaryViewport);
      expect(viewport.navigation.leadingPosition, anchor);
    }
    debugPrint(
      'Before closing reader: ${viewport.navigation.leadingPosition}; expected $anchor',
    );
    await tester.tap(find.byTooltip('Back to library'));
    await tester.pumpAndSettle();
    expect(
      (await store.load()).firstWhere((b) => b.hash == book.hash).lastPosition,
      anchor,
    );
    debugPrint(
      'Saved anchor: ${controller.books.firstWhere((b) => b.hash == book.hash).lastPosition}',
    );
    await tester.tap(find.text('Continue reading'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextViewport>(find.byType(TextViewport))
          .navigation
          .leadingPosition,
      anchor,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextViewport>(find.byType(TextViewport))
          .navigation
          .leadingPosition,
      isNot(anchor),
    );
    await tester.tap(find.byTooltip('Back to library'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Novel').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Novel').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Choose chapter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Passage'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Back to library'));
    await tester.pumpAndSettle();
    await controller.flush();
    await tester.pumpWidget(const SizedBox.shrink());
    await root.delete(recursive: true);
  });
}
