import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/book_service.dart';
import 'package:reader/controller.dart';
import 'package:reader/main.dart';
import 'package:reader/models.dart';
import 'package:reader/storage.dart';
import 'package:reader/text/viewport.dart';

import '../../test/fakes.dart';
import '../../test/fixtures/epub.dart';

/// Owns one native test's real private catalog, parser, and application routes.
/// Only picker input, preferences, and cloud services are replaced with fakes.
/// Cleanup is registered before initialization so assertion/setup failures cannot
/// leave a mounted reader or its temporary book directories behind.
class NativeTestApp {
  NativeTestApp._(this.tester, this.root) : store = FileCatalogStore(root);

  /// Binding shared by scenario actions and teardown to detach routes safely.
  final WidgetTester tester;

  /// Newly created temporary storage; never the user's application-support shelf.
  final Directory root;

  /// Real catalog boundary used to inspect exit persistence.
  final FileCatalogStore store;

  /// Controller owned by ReaderApp after mounting and by this fixture beforehand.
  late final ReaderController controller;
  final _screenshotKey = GlobalKey();
  bool _mounted = false;

  /// Starts an isolated app, optionally seeding books without repeating import UI.
  /// The import scenario uses [importBooks] false to exercise that UI explicitly.
  static Future<NativeTestApp> launch(
    WidgetTester tester, {
    bool importBooks = true,
  }) async {
    final root = await Directory.systemTemp.createTemp('reader_native_test');
    final app = NativeTestApp._(tester, root);
    final txt = Uint8List.fromList(
      utf8.encode(
        List.generate(
          120,
          (i) => 'Paragraph $i: 中文 العربية שָׁלוֹם हिन्दी ไทย e\u0301 👩🏽‍🚀.',
        ).join('\n\n'),
      ),
    );
    final epub = epubFixture();
    app.controller = ReaderController(
      catalogStore: app.store,
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
    addTearDown(app._dispose);
    await app.controller.initialize();
    // ReaderApp assumes ownership as soon as its state is mounted, including
    // when a subsequent pump throws because a test detects a rendering error.
    app._mounted = true;
    await tester.pumpWidget(
      RepaintBoundary(
        key: app._screenshotKey,
        child: ReaderApp(controller: app.controller),
      ),
    );
    if (importBooks) await app.controller.pickAndImport();
    await tester.pumpAndSettle();
    return app;
  }

  /// Current viewport rather than a widget snapshot from an earlier theme/mode.
  TextViewport get viewport =>
      tester.widget<TextViewport>(find.byType(TextViewport));

  /// Painted text slices, excluding macOS's automatically inserted scrollbar.
  Finder get textPaints => find.descendant(
    of: find.byType(TextViewport),
    matching: find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter != null,
    ),
  );

  /// Finds a fixture book by its imported metadata title.
  CatalogBook book(String title) =>
      controller.books.firstWhere((book) => book.title == title);

  /// Opens a real imported document through its library tile.
  Future<void> openBook(String title) async {
    await tester.ensureVisible(find.text(title).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(title).last);
    await tester.pumpAndSettle();
  }

  /// Advances to a non-initial passage before reflow and persistence assertions.
  Future<void> advance() async {
    viewport.navigation.next();
    await tester.pumpAndSettle();
  }

  /// Exercises reader exit, including its position flush, without replacing routes.
  Future<void> closeReader() async {
    await tester.tap(find.byTooltip('Back to library'));
    await tester.pumpAndSettle();
  }

  /// Captures platform rendering outside catalog storage, with a stable artifact
  /// name per scenario and platform. Image resources are always disposed.
  Future<void> capture(String name) async {
    final image =
        await (_screenshotKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
    try {
      final pixels = await image.toByteData(format: ui.ImageByteFormat.png);
      final screenshot = File(
        '${Directory.systemTemp.path}/reader-$name-${Platform.operatingSystem}.png',
      );
      await screenshot.writeAsBytes(pixels!.buffer.asUint8List());
      debugPrint('Reader native screenshot: ${screenshot.path}');
    } finally {
      image.dispose();
    }
  }

  Future<void> _dispose() async {
    try {
      try {
        if (_mounted) {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          controller.dispose();
        }
      } finally {
        // ReaderScreen.dispose queues its own flush. Unmount first, then await
        // a final serialized write so deleting files cannot race that flush.
        await controller.flush();
      }
    } finally {
      // Delete only the directory this fixture created, after readers detach.
      await root.delete(recursive: true);
    }
  }
}

/// Visible preset names shared by library and reader settings scenarios.
String themeLabel(ReadingTheme preset) => switch (preset) {
  ReadingTheme.paper => 'Paper',
  ReadingTheme.sepia => 'Sepia',
  ReadingTheme.dark => 'Dark',
};
