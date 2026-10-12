import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/app/reader_controller.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/narration/mini_player.dart';
import 'package:reader/narration/session.dart';
import 'package:reader/narration/status_indicator.dart';
import 'package:reader/preferences/reader_settings.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/preferences/reading_theme.dart';
import 'package:reader/reader/reader_screen.dart';
import 'package:reader/text/block_slice.dart';
import 'package:reader/text/narration_range.dart';
import 'package:reader/text/narration_follow_target.dart';
import 'package:reader/text/text_page_slices.dart';
import 'package:reader/text/layout/section_layout.dart';
import 'package:reader/text/text_block.dart' as text;
import 'package:reader/text/text_position.dart' as text;
import 'package:reader/text/text_section.dart' as text;
import 'package:reader/text/text_slice_painter.dart';
import 'package:reader/text/viewport.dart';
import 'package:reader/theme.dart';
import 'package:reader/text/reader_navigation.dart';

import 'fixtures/catalog_book.dart';
import 'support/controller_lifecycle.dart';
import 'support/fake_narration_api.dart';
import 'support/memory_document_store.dart';
import 'support/test_controller.dart';

void main() {
  for (final mode in ReadingMode.values) {
    testWidgets(
      '$mode highlights the actual selected paragraph and keeps hidden-chrome status stationary',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 780));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        const committed = text.TextPosition(sectionId: 's0', blockId: 'p0');
        const selected = text.TextPosition(sectionId: 's0', blockId: 'p8');
        final book = testBook(position: committed);
        final documents = MemoryDocumentStore(
          sections: [
            text.TextSection(
              id: 's0',
              blocks: [
                for (var i = 0; i < 10; i++)
                  text.TextBlock(
                    id: 'p$i',
                    text: 'Repeated normalized paragraph prose. ' * 8,
                  ),
              ],
            ),
          ],
        );
        final api = FakeNarrationApi();
        final controller = await _controller(book, documents, api);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await disposeControllerWithFrames(tester, controller);
        });
        await controller.preferences.configure(mode: mode);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildReaderTheme(ReadingTheme.sepia),
            home: ReaderScreen(
              book: book,
              controller: controller,
              documentStore: documents,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await controller.registerNarration(book);
        await controller.narration!.playFrom(selected);
        await tester.pumpAndSettle();

        final active = find.byWidgetPredicate(
          (widget) => widget is BlockSlice && widget.narrationRange != null,
        );
        expect(active, findsOneWidget);
        expect(tester.widget<BlockSlice>(active).block.block.id, 'p8');
        final contentRect = tester.getRect(find.byType(TextViewport));
        expect(tester.getRect(active).overlaps(contentRect), isTrue);
        expect(controller.catalog.books.single.lastPosition, committed);

        final semantics = tester.ensureSemantics();
        await tester.tap(find.byTooltip('Hide reading controls'));
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byType(TextViewport)), contentRect);
        expect(
          find.byKey(const ValueKey('reader-narration-status')),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel('Narration playing'), findsOneWidget);
        expect(find.bySemanticsLabel('Listen'), findsNothing);
        expect(tester.getRect(active).overlaps(contentRect), isTrue);
        expect(controller.catalog.books.single.lastPosition, committed);

        final pause = controller.narration!.pause();
        await tester.pumpAndSettle();
        await pause;
        expect(find.bySemanticsLabel('Narration paused'), findsOneWidget);
        expect(active, findsNothing);
        expect(tester.getRect(find.byType(TextViewport)), contentRect);
        expect(controller.catalog.books.single.lastPosition, committed);

        api.offline = true;
        await controller.narration!.playFrom(
          const text.TextPosition(sectionId: 's0', blockId: 'p2'),
        );
        await tester.pumpAndSettle();
        expect(controller.narration!.status, NarrationStatus.buffering);
        expect(controller.narration!.activeChunk!.start.blockId, 'p2');
        expect(find.bySemanticsLabel('Narration buffering'), findsOneWidget);
        expect(active, findsNothing);
        expect(controller.catalog.books.single.lastPosition, committed);
        semantics.dispose();
      },
    );
  }

  for (final mode in ReadingMode.values) {
    testWidgets(
      '$mode reopening live narration stays silent when paused during initial loading',
      (tester) async {
        const committed = text.TextPosition(sectionId: 's0', blockId: 'p0');
        const spoken = text.TextPosition(sectionId: 's0', blockId: 'p8');
        final book = testBook(position: committed);
        final documents = _DelayedInitialDocuments();
        final controller = await _controller(
          book,
          documents,
          FakeNarrationApi(),
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await disposeControllerWithFrames(tester, controller);
        });
        await controller.preferences.configure(mode: mode);
        await controller.registerNarration(book);
        await controller.narration!.playFrom(spoken);
        expect(controller.narration!.status, NarrationStatus.playing);
        final progress = controller.catalog.books.single.progress;
        documents.delay = true;
        await tester.pumpWidget(
          MaterialApp(
            home: ListenableBuilder(
              listenable: controller,
              builder: (_, _) => ReaderScreen(
                book: book,
                controller: controller,
                documentStore: documents,
              ),
            ),
          ),
        );
        // The enclosing builder must not be notified by initState attachment.
        expect(tester.takeException(), isNull);
        await tester.pump();
        final viewport = tester.widget<TextViewport>(find.byType(TextViewport));
        expect(viewport.initialPosition, spoken);
        expect(find.byType(BlockSlice), findsNothing);

        // An interruption need not restore the viewport. Once ownership drops,
        // only a genuinely silent initial restoration protects this late load.
        await controller.narration!.pause(restore: false);
        expect(controller.narration!.ownsPosition(book), isFalse);
        documents.pending.complete(documents.sections.single);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(viewport.navigation.leadingPosition, spoken);
        expect(controller.catalog.books.single.lastPosition, committed);
        expect(controller.catalog.books.single.progress, progress);
        expect(
          find.byWidgetPredicate(
            (widget) => widget is BlockSlice && widget.narrationRange != null,
          ),
          findsNothing,
        );
      },
    );
  }

  testWidgets('a backgrounded reader rejects its pending highlight attachment', (
    tester,
  ) async {
    final book = testBook();
    final documents = MemoryDocumentStore();
    final controller = await _controller(book, documents, FakeNarrationApi());
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await disposeControllerWithFrames(tester, controller);
    });
    try {
      await controller.registerNarration(book);
      await controller.narration!.play();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            book: book,
            controller: controller,
            documentStore: documents,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.narration!.activeHighlight, isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(controller.narration!.activeHighlight, isNotNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(controller.narration!.activeHighlight, isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(controller.narration!.activeHighlight, isNull);
      expect(tester.takeException(), isNull);
    } finally {
      // The fixture owns app-lifetime resume persistence, not the reader tree.
      await controller.narration!.pause(restore: false);
    }
  });

  testWidgets(
    'an ordinary initial viewport position still reports reading progress',
    (tester) async {
      final documents = _DelayedInitialDocuments()..delay = true;
      const initial = text.TextPosition(sectionId: 's0', blockId: 'p8');
      final positions = <text.TextPosition>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextViewport(
              document: documents.document,
              sourcePath: '/tmp/test.txt',
              store: documents,
              navigation: TextReaderNavigation(),
              settings: const ReaderSettings(),
              foreground: Colors.black,
              initialPosition: initial,
              onPosition: (position, _, _) => positions.add(position),
              onTap: () {},
            ),
          ),
        ),
      );
      expect(positions, isEmpty);
      documents.pending.complete(documents.sections.single);
      await tester.pumpAndSettle();
      expect(positions, [initial]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final theme in ReadingTheme.values) {
    for (final direction in TextDirection.values) {
      testWidgets('$theme $direction paints only clipped spoken glyph boxes', (
        tester,
      ) async {
        final colors = buildReaderTheme(theme).colorScheme;
        final source = direction == TextDirection.rtl
            ? 'العربية الأولى hello العربية الثانية world. ' * 3
            : 'Hello first sentence. Another spoken sentence. ' * 3;
        final painter = TextPainter(
          text: TextSpan(
            text: source,
            style: const TextStyle(color: Colors.transparent, fontSize: 28),
          ),
          textDirection: direction,
        )..layout(maxWidth: 180);
        addTearDown(painter.dispose);
        final metrics = painter.computeLineMetrics();
        final top = metrics[1].baseline - metrics[1].ascent;
        final height = metrics[1].height * 1.5;
        final slice = TextSlicePainter(
          painter,
          top,
          height: height,
          narrationRange: const TextSelection(baseOffset: 5, extentOffset: 55),
          highlightColor: colors.primary.withValues(alpha: .14),
        );
        expect(slice.highlightRects, isNotEmpty);
        for (final rect in slice.highlightRects) {
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(painter.width));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThanOrEqualTo(height));
        }
        final recolored = TextSlicePainter(
          painter,
          top,
          height: height,
          narrationRange: slice.narrationRange,
          highlightColor: Colors.red,
          previous: slice,
        );
        expect(recolored.highlightRects, same(slice.highlightRects));
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawColor(colors.surface, BlendMode.src);
        slice.paint(canvas, Size(180, height));
        final picture = recorder.endRecording();
        addTearDown(picture.dispose);
        final image = await tester.runAsync(() => picture.toImage(200, 120));
        addTearDown(image!.dispose);
        final data = await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        final paper = colors.surface.toARGB32();
        final paperRgba = ((paper & 0xffffff) << 8) | (paper >> 24);
        var colored = 0;
        for (var y = 0; y < 120; y++) {
          for (var x = 0; x < 200; x++) {
            if (data!.getUint32((y * 200 + x) * 4) == paperRgba) continue;
            colored++;
            expect(
              slice.highlightRects.any(
                (rect) => rect.inflate(.5).contains(Offset(x + .5, y + .5)),
              ),
              isTrue,
              reason: 'No wash outside visible spoken glyph boxes at $x,$y',
            );
          }
        }
        expect(colored, greaterThan(0));
      });
    }
  }

  testWidgets('mini-player explicitly presents playing paused and buffering', (
    tester,
  ) async {
    final book = testBook();
    final api = FakeNarrationApi();
    final controller = await _controller(book, MemoryDocumentStore(), api);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await disposeControllerWithFrames(tester, controller);
    });
    await controller.registerNarration(book);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildReaderTheme(ReadingTheme.dark),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => NarrationMiniPlayer(controller: controller),
          ),
        ),
      ),
    );
    expect(find.text('Narration paused'), findsOneWidget);
    await controller.narration!.play();
    await tester.pumpAndSettle();
    expect(find.text('Narration playing'), findsOneWidget);
    await controller.narration!.pause();
    await tester.pumpAndSettle();
    expect(find.text('Narration paused'), findsOneWidget);
    api.offline = true;
    await controller.narration!.playFrom(
      const text.TextPosition(sectionId: 's0', blockId: 'p1', offset: 3),
    );
    await tester.pumpAndSettle();
    expect(find.text('Narration buffering'), findsOneWidget);
    expect(find.byType(NarrationStatusIndicator), findsOneWidget);
  });

  testWidgets(
    'spoken-range paint validates complete identity without reflow or commits',
    (tester) async {
      final documents = MemoryDocumentStore();
      final navigation = TextReaderNavigation();
      var commits = 0;
      Future<void> mount(NarrationRange? active) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TextViewport(
                document: documents.document,
                sourcePath: '/tmp/test.txt',
                store: documents,
                navigation: navigation,
                settings: const ReaderSettings(),
                foreground: Colors.black,
                onPosition: (_, _, _) => commits++,
                onTap: () {},
                activeNarrationRange: active,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await mount(null);
      final initialCommits = commits;
      final slice = find.byWidgetPredicate(
        (widget) => widget is BlockSlice && widget.block.block.id == 'p1',
      );
      final before = tester.widget<BlockSlice>(slice);
      final geometry = tester.getRect(slice);
      await mount(
        NarrationRange(
          const text.TextPosition(sectionId: 's0', blockId: 'p1', offset: 5),
          const text.TextPosition(sectionId: 's0', blockId: 'p1', offset: 10),
        ),
      );
      expect(
        tester.widget<BlockSlice>(slice).narrationRange,
        const TextSelection(baseOffset: 5, extentOffset: 10),
      );
      expect(
        tester.widget<BlockSlice>(slice).block.painter,
        same(before.block.painter),
      );
      expect(tester.getRect(slice), geometry);
      expect(commits, initialCommits);

      for (final unrelated in [
        _range('other-section', 'p1', 0, 4),
        _range('s0', 'missing-block', 0, 4),
        _range('s0', 'p1', 0, 999),
      ]) {
        await mount(unrelated);
        expect(tester.widget<BlockSlice>(slice).narrationRange, isNull);
        expect(tester.getRect(slice), geometry);
        expect(commits, initialCommits);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'page fragments intersect spoken offsets and preserve borrowed painters',
    (tester) async {
      const source =
          'First spoken sentence. Second adjacent sentence. '
          'Third sentence which wraps onto several measured lines.';
      final section = text.TextSection(
        id: 's0',
        blocks: const [text.TextBlock(id: 'p0', text: source)],
      );
      final layout = SectionLayout(
        section,
        130,
        50,
        const TextStyle(fontSize: 22, height: 1.4),
        TextScaler.noScaling,
      );
      addTearDown(layout.dispose);
      final range = _range('s0', 'p0', 6, 30);
      var covered = 0;
      for (final page in layout.pages) {
        final slices = textPageSlices(
          page,
          sectionId: 's0',
          activeNarrationRange: range,
        ).cast<BlockSlice>();
        for (final slice in slices) {
          expect(slice.block.painter, same(layout.blocks.single.painter));
          final highlight = slice.narrationRange;
          if (highlight == null) {
            expect(slice.end <= 6 || slice.start >= 30, isTrue);
          } else {
            expect(highlight.start, greaterThanOrEqualTo(slice.start));
            expect(highlight.end, lessThanOrEqualTo(slice.end));
            expect(highlight.start, greaterThanOrEqualTo(6));
            expect(highlight.end, lessThanOrEqualTo(30));
            covered += highlight.end - highlight.start;
          }
        }
      }
      expect(covered, 24);
    },
  );

  testWidgets('spoken decoration rejects offsets inside a source grapheme', (
    tester,
  ) async {
    final section = text.TextSection(
      id: 's0',
      blocks: const [text.TextBlock(id: 'p0', text: 'é 👩🏽‍🚀 spoken text.')],
    );
    final layout = SectionLayout(
      section,
      200,
      100,
      const TextStyle(fontSize: 24),
      TextScaler.noScaling,
    );
    addTearDown(layout.dispose);
    TextSelection? offsets(NarrationRange range) => narrationBlockRange(
      range: range,
      sectionId: 's0',
      block: layout.blocks.single,
    );
    expect(offsets(_range('s0', 'p0', 1, 2)), isNull);
    expect(offsets(_range('s0', 'p0', 0, 1)), isNull);
    expect(
      offsets(_range('s0', 'p0', 0, 2)),
      const TextSelection(baseOffset: 0, extentOffset: 2),
    );
  });

  testWidgets(
    'follow visibility uses complete logical lines in scroll and pages',
    (tester) async {
      final section = text.TextSection(
        id: 's0',
        blocks: [
          text.TextBlock(id: 'p0', text: 'A long spoken paragraph. ' * 30),
        ],
      );
      final layout = SectionLayout(
        section,
        160,
        90,
        const TextStyle(fontSize: 24, height: 1.5),
        TextScaler.noScaling,
      );
      addTearDown(layout.dispose);
      final line = layout.lines[5];
      final target = line.position('s0');
      bool visible({int? page, double scroll = 0, double extent = 90}) =>
          narrationTargetVisible(
            target: target,
            sectionId: 's0',
            layout: layout,
            page: page,
            scrollOffset: scroll,
            viewportExtent: extent,
          );
      expect(visible(), isFalse);
      expect(visible(scroll: line.globalTop), isTrue);
      expect(visible(scroll: line.globalTop + 1), isFalse);
      expect(visible(scroll: line.globalTop, extent: line.height - 1), isFalse);
      final page = layout.pages.indexWhere((page) => page.contains(line));
      expect(visible(page: page), isTrue);
      expect(visible(page: 0), isFalse);
      expect(
        narrationTargetVisible(
          target: const text.TextPosition(sectionId: 's0', blockId: 'missing'),
          sectionId: 's0',
          layout: layout,
          page: null,
          scrollOffset: 0,
          viewportExtent: 90,
        ),
        isFalse,
      );
    },
  );

  for (final mode in ReadingMode.values) {
    testWidgets(
      '$mode follows later lines silently but leaves visible text still',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 500));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final source = 'A spoken line within one very tall paragraph. ' * 80;
        final documents = MemoryDocumentStore(
          sections: [
            text.TextSection(
              id: 's0',
              blocks: [text.TextBlock(id: 'p0', text: source)],
            ),
          ],
        );
        final navigation = TextReaderNavigation();
        var commits = 0;
        var manualMoves = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TextViewport(
                document: documents.document,
                sourcePath: '/tmp/test.txt',
                store: documents,
                navigation: navigation,
                settings: ReaderSettings(mode: mode),
                foreground: Colors.black,
                onPosition: (_, _, _) => commits++,
                onManualNavigation: () => manualMoves++,
                onTap: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final initialCommits = commits;
        final initial = navigation.leadingPosition;
        await navigation.follow(
          const text.TextPosition(sectionId: 's0', blockId: 'p0', offset: 2),
        );
        expect(navigation.leadingPosition, initial);
        final target = text.TextPosition(
          sectionId: 's0',
          blockId: 'p0',
          offset: source.length - 40,
        );
        final following = navigation.follow(target);
        await tester.pumpAndSettle();
        await following;
        expect(navigation.leadingPosition, target);
        final after = tester.getRect(find.byType(BlockSlice).first);
        await navigation.follow(target);
        expect(tester.getRect(find.byType(BlockSlice).first), after);
        expect(commits, initialCommits);
        expect(manualMoves, 0);
        expect(navigation.retainedLayoutCount, lessThanOrEqualTo(2));
        expect(navigation.retainedTextureCount, 0);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'a fenced pending spoken follow cannot apply a late section load',
    (tester) async {
      final documents = _DelayedFollowDocuments();
      final navigation = TextReaderNavigation();
      var commits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextViewport(
              document: documents.document,
              sourcePath: '/tmp/test.txt',
              store: documents,
              navigation: navigation,
              settings: const ReaderSettings(),
              foreground: Colors.black,
              onPosition: (_, _, _) => commits++,
              onTap: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final initial = navigation.leadingPosition;
      final initialCommits = commits;
      var current = true;
      final following = navigation.follow(
        const text.TextPosition(sectionId: 's1', blockId: 'p1', offset: 4),
        isCurrent: () => current,
      );
      await tester.pump();
      current = false;
      documents.pending.complete(documents.sections[1]);
      await tester.pumpAndSettle();
      await following;
      expect(navigation.leadingPosition, initial);
      expect(commits, initialCommits);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

/// Offline boundaries exercise the actual controller, session and viewport.
Future<ReaderController> _controller(
  CatalogBook book,
  MemoryDocumentStore documents,
  FakeNarrationApi api,
) => testController(
  books: [book],
  narrationApi: api,
  narrationDocuments: documents,
);

NarrationRange _range(String section, String block, int start, int end) =>
    NarrationRange(
      text.TextPosition(sectionId: section, blockId: block, offset: start),
      text.TextPosition(sectionId: section, blockId: block, offset: end),
    );

class _DelayedFollowDocuments extends MemoryDocumentStore {
  _DelayedFollowDocuments()
    : super(
        sections: const [
          text.TextSection(
            id: 's0',
            blocks: [
              text.TextBlock(id: 'p0', text: 'The current readable paragraph.'),
            ],
          ),
          text.TextSection(
            id: 's1',
            blocks: [
              text.TextBlock(id: 'p1', text: 'A later narrated section.'),
            ],
          ),
        ],
      );

  final pending = Completer<text.TextSection>();

  @override
  Future<text.TextSection> loadSection(String sourcePath, String id) =>
      id == 's1' ? pending.future : super.loadSection(sourcePath, id);
}

class _DelayedInitialDocuments extends MemoryDocumentStore {
  _DelayedInitialDocuments()
    : super(
        sections: [
          text.TextSection(
            id: 's0',
            blocks: [
              for (var i = 0; i < 10; i++)
                text.TextBlock(
                  id: 'p$i',
                  text: 'Repeated normalized paragraph prose. ' * 8,
                ),
            ],
          ),
        ],
      );

  bool delay = false;
  final pending = Completer<text.TextSection>();

  @override
  Future<text.TextSection> loadSection(String sourcePath, String id) =>
      delay ? pending.future : super.loadSection(sourcePath, id);
}
