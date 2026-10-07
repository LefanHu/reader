import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/models.dart';
import 'package:reader/illustrations/gate.dart';
import 'package:reader/illustrations/models.dart';
import 'package:reader/text/document.dart' as text;
import 'package:reader/text/page_curl.dart';
import 'package:reader/text/viewport.dart';

import 'fakes.dart';

const _multilingual = '中文 العربية שָׁלוֹם हिन्दी ไทย e\u0301 👩🏽‍🚀 ';

/// Keeps changes observable without replacing the viewport's element/state.
class _Harness {
  _Harness({MemoryDocumentStore? store, this.reducedMotion = false})
    : store =
          store ??
          MemoryDocumentStore(
            sections: [
              text.TextSection(
                id: 's0',
                blocks: [text.TextBlock(id: 'p0', text: _multilingual * 80)],
              ),
            ],
          );
  final MemoryDocumentStore store;
  final bool reducedMotion;
  final navigation = TextReaderNavigation();
  final reports = <text.TextPosition>[];
  final settings = ValueNotifier(
    const ReaderSettings(mode: ReadingMode.pageFlip),
  );
  Size size = const Size(360, 260);
  int taps = 0;

  Widget app() => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: ValueListenableBuilder(
            valueListenable: settings,
            builder: (context, value, _) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: reducedMotion),
              child: TextViewport(
                document: store.document,
                sourcePath: '/memory/book',
                store: store,
                navigation: navigation,
                settings: value,
                foreground: Colors.black,
                background: const Color(0xfffffbf0),
                onPosition: (p, _, _) => reports.add(p),
                onTap: () => taps++,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> mount(WidgetTester tester) async {
    addTearDown(settings.dispose);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    reports.clear();
  }
}

/// Simulates chapter I/O that can fail or complete after a navigation override.
class _DelayedStore extends MemoryDocumentStore {
  _DelayedStore()
    : super(
        sections: [
          const text.TextSection(
            id: 's0',
            blocks: [text.TextBlock(id: 'a', text: 'First page')],
          ),
          const text.TextSection(
            id: 's1',
            blocks: [text.TextBlock(id: 'b', text: 'Second page')],
          ),
          const text.TextSection(
            id: 's2',
            blocks: [text.TextBlock(id: 'c', text: 'Third page')],
          ),
        ],
      );
  Completer<void>? pending;
  bool fail = false;
  @override
  Future<text.TextSection> loadSection(String sourcePath, String id) async {
    if (id == 's1') {
      if (fail) throw StateError('unavailable section');
      await pending?.future;
    }
    return super.loadSection(sourcePath, id);
  }
}

void main() {
  for (final mode in [ReadingMode.pages, ReadingMode.pageFlip]) {
    testWidgets('${mode.name} restores scrolling on its first visible frame', (
      tester,
    ) async {
      final h = _Harness();
      await h.mount(tester);
      h.settings.value = h.settings.value.copyWith(mode: mode);
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        h.navigation.next();
        await tester.pumpAndSettle();
      }
      final anchor = h.navigation.leadingPosition!;
      expect(anchor.offset, greaterThan(0));
      h.settings.value = h.settings.value.copyWith(mode: ReadingMode.scroll);
      await tester.pump();
      final scrollable = find.descendant(
        of: find.byType(TextViewport),
        matching: find.byType(Scrollable),
      );
      final paints = find.descendant(
        of: find.byType(TextViewport),
        matching: find.byType(CustomPaint),
      );
      final firstOffset = tester
          .state<ScrollableState>(scrollable)
          .position
          .pixels;
      final firstText = tester.getRect(paints.first);
      expect(firstOffset, greaterThan(0));
      expect(h.navigation.leadingPosition, anchor);
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        firstOffset,
      );
      expect(tester.getRect(paints.first), firstText);
      // An old Scroll pixel offset must not override a newer paginated anchor.
      h.settings.value = h.settings.value.copyWith(mode: mode);
      await tester.pumpAndSettle();
      h.navigation.next();
      await tester.pumpAndSettle();
      final nextAnchor = h.navigation.leadingPosition;
      h.settings.value = h.settings.value.copyWith(mode: ReadingMode.scroll);
      await tester.pump();
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        greaterThan(firstOffset),
      );
      expect(h.navigation.leadingPosition, nextAnchor);
      h.settings.value = h.settings.value.copyWith(mode: mode);
      await tester.pump();
      h.settings.value = h.settings.value.copyWith(mode: ReadingMode.scroll);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, nextAnchor);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('chapter jumps invalidate pending mode restoration reports', (
    tester,
  ) async {
    final h = _Harness(
      store: MemoryDocumentStore(
        sections: [
          text.TextSection(
            id: 's0',
            blocks: [text.TextBlock(id: 'p0', text: _multilingual * 80)],
          ),
          const text.TextSection(
            id: 's1',
            blocks: [text.TextBlock(id: 'p1', text: 'Next chapter')],
          ),
        ],
      ),
    );
    await h.mount(tester);
    h.reports.clear();
    // Run the chapter command ahead of the restoration callback in this frame.
    tester.binding.addPostFrameCallback(
      (_) => h.navigation.goTo(
        const text.TextPosition(sectionId: 's1', blockId: 'p1'),
      ),
    );
    h.settings.value = h.settings.value.copyWith(mode: ReadingMode.scroll);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(h.navigation.leadingPosition!.sectionId, 's1');
    expect(h.reports, isNotEmpty);
    expect(h.reports.every((position) => position.sectionId == 's1'), isTrue);
    expect(tester.takeException(), isNull);
  });

  test('page flip settings round trip without changing old defaults', () {
    const setting = ReaderSettings(mode: ReadingMode.pageFlip);
    expect(
      ReaderSettings.fromJson(setting.toJson()).mode,
      ReadingMode.pageFlip,
    );
    expect(ReaderSettings.fromJson({}).mode, ReadingMode.scroll);
    for (final mode in [ReadingMode.pages, ReadingMode.scroll]) {
      expect(ReaderSettings.fromJson({'mode': mode.name}).mode, mode);
    }
  });

  testWidgets(
    'page flip commits the same measured anchor as immediate pages once',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final start = h.navigation.leadingPosition;
      h.settings.value = h.settings.value.copyWith(mode: ReadingMode.pages);
      await tester.pumpAndSettle();
      h.navigation.next();
      await tester.pumpAndSettle();
      final expected = h.navigation.leadingPosition;
      h.navigation.previous();
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, start);
      h.settings.value = h.settings.value.copyWith(mode: ReadingMode.pageFlip);
      await tester.pumpAndSettle();
      h.reports.clear();
      h.navigation.next();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));
      expect(h.navigation.leadingPosition, start);
      expect(h.reports, isEmpty);
      expect(h.navigation.retainedTextureCount, 2);
      h.navigation.next(); // Requests during settling do not queue extra turns.
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, expected);
      expect(h.reports, [expected]);
      expect(h.navigation.retainedTextureCount, 0);
      expect(
        text.graphemeFloor(
          h.store.sections.first.blocks.first.text,
          expected!.offset,
        ),
        expected.offset,
      );
    },
  );

  testWidgets(
    'cancelled drag preserves anchor and completed drag advances after release',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final start = h.navigation.leadingPosition;
      final center = tester.getCenter(find.byType(TextViewport));
      var gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump(const Duration(milliseconds: 200));
      expect(h.navigation.leadingPosition, start);
      expect(h.navigation.retainedTextureCount, 2);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, start);
      expect(h.reports, isEmpty);
      expect(h.navigation.retainedTextureCount, 0);
      gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-150, 0));
      await tester.pump(const Duration(milliseconds: 200));
      expect(h.navigation.leadingPosition, start);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, isNot(start));
      expect(h.reports, hasLength(1));
      expect(h.taps, 0);
    },
  );

  testWidgets('fast short flick completes and reversed release cancels', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    final start = h.navigation.leadingPosition;
    await tester.fling(find.byType(TextViewport), const Offset(-95, 0), 1000);
    await tester.pumpAndSettle();
    expect(h.navigation.leadingPosition, isNot(start));
    h.navigation.previous();
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TextViewport)),
    );
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveBy(
      const Offset(20, 0),
      timeStamp: const Duration(milliseconds: 310),
    );
    await gesture.up(timeStamp: const Duration(milliseconds: 311));
    await tester.pumpAndSettle();
    expect(h.navigation.leadingPosition, start);
  });

  testWidgets('illustrations stay locked through previews and cancellations', (
    tester,
  ) async {
    final h = _Harness(store: _DelayedStore());
    await h.mount(tester);
    final index = BookTextIndex(
      bookHash: 'book',
      chapters: [
        for (var i = 0; i < h.store.sections.length; i++)
          ChapterTextIndex(
            href: 's$i',
            spineOrdinal: i,
            title: null,
            paragraphs: [
              IndexedParagraph(
                id: h.store.sections[i].blocks.first.id,
                text: h.store.sections[i].blocks.first.text,
                cssSelector: '',
                ordinal: 0,
                progression: 0,
              ),
            ],
          ),
      ],
    );
    const anchor = SceneAnchor(
      href: 's0',
      spineOrdinal: 0,
      paragraphId: 'a',
      cssSelector: '',
      fallbackProgression: 0,
    );
    bool unlocked() => const IllustrationGate().hasPassed(
      anchor: anchor,
      index: index,
      position: h.navigation.leadingPosition!,
    );
    expect(unlocked(), false);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TextViewport)),
    );
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-130, 0));
    await tester.pump();
    expect(unlocked(), false);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(unlocked(), false);
    h.navigation.next();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(unlocked(), false);
    await tester.pumpAndSettle();
    expect(unlocked(), true);
  });

  testWidgets(
    'large viewports cap both texture resolutions and release ownership',
    (tester) async {
      tester.view.physicalSize = const Size(3200, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = _Harness(store: _DelayedStore())..size = const Size(3000, 1000);
      await h.mount(tester);
      h.navigation.next();
      await tester.pump();
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<PaperCurlPainter>()
          .single;
      for (final image in [painter.current, painter.target]) {
        expect(image.width, lessThanOrEqualTo(2048));
        expect(image.height, lessThanOrEqualTo(2048));
        expect(image.height, lessThanOrEqualTo(2000));
      }
      await tester.pumpAndSettle();
      expect(h.navigation.retainedTextureCount, 0);
      h.navigation.next();
      await tester.pumpAndSettle();
      h.navigation.previous();
      await tester.pumpAndSettle();
      expect(h.navigation.retainedLayoutCount, lessThanOrEqualTo(2));
      expect(h.navigation.retainedTextureCount, 0);
    },
  );

  testWidgets(
    'edge taps and RTL keys turn logically while center toggles controls',
    (tester) async {
      final h = _Harness(
        store: MemoryDocumentStore(
          sections: [
            text.TextSection(
              id: 's0',
              blocks: [text.TextBlock(id: 'rtl', text: 'שלום עולם ' * 120)],
            ),
          ],
        ),
      );
      await h.mount(tester);
      final rect = tester.getRect(find.byType(TextViewport));
      final start = h.navigation.leadingPosition;
      await tester.tapAt(rect.center);
      expect(h.taps, 1);
      await tester.tapAt(Offset(rect.left + 30, rect.center.dy));
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, isNot(start));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, start);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, isNot(start));
      await tester.tapAt(Offset(rect.right - 30, rect.center.dy));
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, start);
    },
  );

  testWidgets(
    'reflow mode changes suspension and disposal discard uncommitted turns',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final start = h.navigation.leadingPosition;
      h.navigation.next();
      await tester.pump();
      h.settings.value = h.settings.value.copyWith(fontSize: 150);
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, start);
      h.navigation.next();
      await tester.pump();
      h.size = const Size(420, 300);
      await tester.pumpWidget(h.app());
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, start);
      h.navigation.next();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, start);
      expect(h.navigation.retainedTextureCount, 0);
      h.navigation.next();
      await tester.pump();
      h.settings.value = h.settings.value.copyWith(mode: ReadingMode.scroll);
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition, start);
      h.settings.value = h.settings.value.copyWith(mode: ReadingMode.pageFlip);
      await tester.pumpAndSettle();
      h.navigation.next();
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(h.navigation.retainedTextureCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'chapter loads stay on committed page and stale loads cannot override jumps',
    (tester) async {
      final store = _DelayedStore()..pending = Completer<void>();
      final h = _Harness(store: store);
      await h.mount(tester);
      final start = h.navigation.leadingPosition;
      h.navigation.next();
      h.navigation.next();
      await tester.pump();
      expect(h.navigation.leadingPosition, start);
      expect(find.bySemanticsLabel('First page'), findsOneWidget);
      h.navigation.goTo(store.sections.last.start);
      await tester.pumpAndSettle();
      store.pending!.complete();
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition!.sectionId, 's2');
      expect(h.navigation.retainedTextureCount, 0);
    },
  );

  testWidgets(
    'drag released during section loading settles from its recorded fraction',
    (tester) async {
      for (final complete in [true, false]) {
        await tester.pumpWidget(const SizedBox.shrink());
        final store = _DelayedStore()..pending = Completer<void>();
        final h = _Harness(store: store);
        await h.mount(tester);
        final start = h.navigation.leadingPosition;
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(TextViewport)),
        );
        await gesture.moveBy(const Offset(-20, 0));
        await tester.pump();
        await gesture.moveBy(const Offset(-160, 0));
        await tester.pump(const Duration(milliseconds: 200));
        if (complete) {
          await gesture.up();
        } else {
          await gesture.cancel();
        }
        expect(h.navigation.leadingPosition, start);
        expect(h.navigation.retainedTextureCount, 0);
        store.pending!.complete();
        await tester.pump();
        await tester.pump();
        final painter = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((w) => w.painter)
            .whereType<PaperCurlPainter>()
            .single;
        expect(painter.progress, greaterThan(.35));
        expect(h.navigation.leadingPosition, start);
        await tester.pumpAndSettle();
        expect(h.navigation.leadingPosition!.sectionId, complete ? 's1' : 's0');
        expect(h.reports, hasLength(complete ? 1 : 0));
        expect(h.navigation.retainedTextureCount, 0);
      }
    },
  );

  testWidgets('failed adjacent page load offers retry without losing anchor', (
    tester,
  ) async {
    final store = _DelayedStore()..fail = true;
    final h = _Harness(store: store);
    await h.mount(tester);
    final start = h.navigation.leadingPosition;
    h.navigation.next();
    await tester.pumpAndSettle();
    expect(h.navigation.leadingPosition, start);
    expect(find.text('Could not load page. Retry'), findsOneWidget);
    store.fail = false;
    await tester.tap(find.text('Could not load page. Retry'));
    await tester.pumpAndSettle();
    expect(h.navigation.leadingPosition!.sectionId, 's1');
    expect(h.reports, hasLength(1));
    expect(h.navigation.retainedLayoutCount, lessThanOrEqualTo(2));
  });

  testWidgets('reduced motion retains paragraph semantics and no textures', (
    tester,
  ) async {
    final h = _Harness(store: _DelayedStore(), reducedMotion: true);
    final semantics = tester.ensureSemantics();
    await h.mount(tester);
    h.navigation.previous();
    await tester.pumpAndSettle();
    expect(h.reports, isEmpty);
    h.navigation.next();
    await tester.pump();
    expect(h.navigation.leadingPosition!.sectionId, 's1');
    expect(find.bySemanticsLabel('Second page'), findsOneWidget);
    expect(h.navigation.retainedTextureCount, 0);
    h.navigation.previous();
    await tester.pumpAndSettle();
    expect(h.navigation.leadingPosition!.sectionId, 's0');
    semantics.dispose();
  });

  testWidgets(
    'preview semantics exclude future paragraphs and final turn completes without blank page',
    (tester) async {
      final h = _Harness(store: _DelayedStore());
      final semantics = tester.ensureSemantics();
      await h.mount(tester);
      h.navigation.next();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.bySemanticsLabel('First page'), findsOneWidget);
      expect(find.bySemanticsLabel('Second page'), findsNothing);
      await tester.pumpAndSettle();
      h.navigation.next();
      await tester.pumpAndSettle();
      final lastStart = h.navigation.leadingPosition;
      h.reports.clear();
      h.navigation.next();
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition!.offset, 'Third page'.length);
      expect(h.reports, hasLength(1));
      expect(find.bySemanticsLabel('Third page'), findsOneWidget);
      h.navigation.previous();
      await tester.pumpAndSettle();
      expect(h.navigation.leadingPosition!.sectionId, 's1');
      expect(h.navigation.leadingPosition, isNot(lastStart));
      expect(h.navigation.retainedLayoutCount, lessThanOrEqualTo(2));
      semantics.dispose();
    },
  );

  testWidgets(
    'curl pixels have exact endpoints mirrored folds and theme-colored reverse',
    (tester) async {
      // Pixel assertions protect geometry and shading without platform font goldens.
      await tester.runAsync(() async {
        const size = Size(240, 160);
        ui.Image page(Color paper, String title) {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawColor(paper, BlendMode.src);
          final text = TextPainter(
            text: TextSpan(
              text: '$title $_multilingual',
              style: TextStyle(
                fontSize: 16,
                color: paper.computeLuminance() < .1
                    ? Colors.white
                    : Colors.black,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: size.width);
          text.paint(canvas, const Offset(8, 8));
          text.dispose();
          final picture = recorder.endRecording();
          final result = picture.toImageSync(240, 160);
          picture.dispose();
          return result;
        }

        Future<Uint8List> paint(
          ui.Image current,
          ui.Image target,
          Color paper,
          double p,
          bool right, {
          bool forward = true,
        }) async {
          final recorder = ui.PictureRecorder();
          PaperCurlPainter(
            current: current,
            target: target,
            progress: p,
            forward: forward,
            fromRight: right,
            paper: paper,
          ).paint(Canvas(recorder), size);
          final picture = recorder.endRecording();
          final image = await picture.toImage(240, 160);
          picture.dispose();
          final data = await image.toByteData();
          image.dispose();
          return data!.buffer.asUint8List();
        }

        for (final paper in [
          const Color(0xfffffbf0),
          const Color(0xfff2e4c9),
          const Color(0xff202124),
        ]) {
          final current = page(paper, 'Current');
          final target = page(paper, 'Next');
          final zero = await paint(current, target, paper, 0, true);
          final one = await paint(current, target, paper, 1, true);
          expect(zero, (await current.toByteData())!.buffer.asUint8List());
          expect(one, (await target.toByteData())!.buffer.asUint8List());
          final mid = await paint(current, target, paper, .3, true);
          expect(mid, isNot(zero));
          expect(mid, isNot(one));
          expect(await paint(current, target, paper, .3, true), mid);
          final mirrored = await paint(current, target, paper, .3, false);
          expect(mirrored, isNot(mid));
          expect(
            await paint(target, current, paper, .7, true, forward: false),
            mid,
          );
          // Below the printed text, the reversed paper is shaded but opaque.
          final offset = (140 * 240 + 80) * 4;
          expect(mid[offset + 3], 255);
          expect((mid[offset] - (paper.r * 255).round()).abs(), lessThan(40));
          current.dispose();
          target.dispose();
        }
      });
    },
  );
}
