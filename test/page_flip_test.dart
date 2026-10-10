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

/// Rasterizes a live preview without taking ownership of viewport textures.
Future<Uint8List> _previewPixels(WidgetTester tester) async {
  final finder = find.byWidgetPredicate(
    (widget) => widget is CustomPaint && widget.painter is PaperCurlPainter,
  );
  final painter = tester.widget<CustomPaint>(finder).painter!;
  return (await tester.runAsync(
    () => _rasterPixels(painter, tester.getSize(finder)),
  ))!;
}

Future<Uint8List> _rasterPixels(CustomPainter painter, Size size) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(size.width.round(), size.height.round());
    return (await image.toByteData())!.buffer.asUint8List();
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

Rect _pageBounds(WidgetTester tester) {
  final viewport = tester.getRect(find.byType(TextViewport));
  return Rect.fromLTRB(
    viewport.left + 20,
    viewport.top + 12,
    viewport.right - 20,
    viewport.bottom - 12,
  );
}

PaperCurlPainter _previewPainter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((widget) => widget.painter)
    .whereType<PaperCurlPainter>()
    .single;

void _expectOpaque(Uint8List pixels) {
  var transparentPixels = 0;
  for (var i = 3; i < pixels.length; i += 4) {
    if (pixels[i] != 255) transparentPixels++;
  }
  expect(transparentPixels, 0, reason: 'Every curl pixel must be opaque');
}

double _differentPixelFraction(Uint8List a, Uint8List b, {int tolerance = 0}) {
  var different = 0;
  for (var i = 0; i < a.length; i += 4) {
    for (var channel = 0; channel < 4; channel++) {
      if ((a[i + channel] - b[i + channel]).abs() > tolerance) {
        different++;
        break;
      }
    }
  }
  return different / (a.length ~/ 4);
}

void main() {
  for (final rtl in [false, true]) {
    for (final forward in [true, false]) {
      testWidgets(
        '${rtl ? 'RTL' : 'LTR'} ${forward ? 'forward' : 'backward'} curls follow grab height and live pointer without committing previews',
        (tester) async {
          final h = _Harness(
            store: rtl
                ? MemoryDocumentStore(
                    sections: [
                      text.TextSection(
                        id: 's0',
                        blocks: [
                          text.TextBlock(id: 'rtl', text: 'שלום עולם ' * 120),
                        ],
                      ),
                    ],
                  )
                : null,
          );
          await h.mount(tester);
          if (!forward) {
            h.navigation.next();
            await tester.pumpAndSettle();
          }
          final start = h.navigation.leadingPosition;
          if (forward) {
            h.navigation.next();
          } else {
            h.navigation.previous();
          }
          await tester.pumpAndSettle();
          final expected = h.navigation.leadingPosition;
          expect(expected, isNot(start));
          if (forward) {
            h.navigation.previous();
          } else {
            h.navigation.next();
          }
          await tester.pumpAndSettle();
          expect(h.navigation.leadingPosition, start);
          h.reports.clear();

          final bounds = _pageBounds(tester);
          final sign = forward == rtl ? 1.0 : -1.0;
          final previews = <Uint8List>[];
          final verticalGesture = await tester.startGesture(bounds.center);
          var verticalReleased = false;
          try {
            await verticalGesture.moveBy(Offset(0, bounds.height * .2));
            await tester.pump();
            expect(h.navigation.leadingPosition, start);
            expect(h.navigation.retainedTextureCount, 0);
            expect(h.reports, isEmpty);
            await verticalGesture.cancel();
            verticalReleased = true;
            await tester.pumpAndSettle();
          } finally {
            if (!verticalReleased) await verticalGesture.cancel();
            await tester.pumpAndSettle();
          }

          for (final height in [.2, .5, .8]) {
            final origin = Offset(
              bounds.center.dx,
              bounds.top + bounds.height * height,
            );
            final heldPosition = origin + Offset(sign * bounds.width * .25, 0);
            final gesture = await tester.startGesture(origin);
            var released = false;
            try {
              await gesture.moveBy(Offset(sign * 20, 0));
              await tester.pump();
              await gesture.moveTo(heldPosition);
              await tester.pump();
              final held = await _previewPixels(tester);
              previews.add(held);
              final progress = _previewPainter(tester).progress;
              expect(progress, closeTo(.25, .000001));
              expect(h.navigation.retainedTextureCount, 2);

              // Full localPosition remains two-dimensional after horizontal
              // recognition; a vertical update changes only the rendered bend.
              await gesture.moveTo(
                heldPosition + Offset(0, bounds.height * .1),
              );
              await tester.pump();
              expect(await _previewPixels(tester), isNot(held));
              expect(_previewPainter(tester).progress, progress);
              expect(h.navigation.leadingPosition, start);
              expect(h.reports, isEmpty);
              await gesture.moveTo(heldPosition);
              await tester.pump();
              expect(await _previewPixels(tester), held);

              // Crossing the grab clamps progress at zero, but returning to
              // the same pointer restores the same preview, not accumulated
              // clamped deltas or a newly selected logical direction.
              await gesture.moveTo(
                origin + Offset(-sign * bounds.width * .05, 0),
              );
              await tester.pump();
              expect(_previewPainter(tester).progress, 0);
              await gesture.moveTo(heldPosition);
              await tester.pump();
              expect(await _previewPixels(tester), held);
              expect(_previewPainter(tester).progress, progress);
              expect(h.navigation.leadingPosition, start);
              expect(h.reports, isEmpty);
              await gesture.cancel();
              released = true;
              await tester.pumpAndSettle();
              expect(h.navigation.leadingPosition, start);
              expect(h.reports, isEmpty);
              expect(h.navigation.retainedTextureCount, 0);
              expect(h.navigation.retainedLayoutCount, lessThanOrEqualTo(2));
            } finally {
              if (!released) await gesture.cancel();
              await tester.pumpAndSettle();
            }
          }
          expect(previews[0], isNot(previews[1]));
          expect(previews[1], isNot(previews[2]));
          expect(previews[0], isNot(previews[2]));

          final origin = Offset(
            bounds.center.dx,
            bounds.top + bounds.height * .2,
          );
          final gesture = await tester.startGesture(origin);
          var released = false;
          try {
            await gesture.moveBy(Offset(sign * 20, 0));
            await tester.pump();
            await gesture.moveTo(
              origin + Offset(sign * bounds.width * .5, bounds.height * .1),
            );
            await tester.pump(const Duration(milliseconds: 200));
            expect(h.navigation.leadingPosition, start);
            expect(h.reports, isEmpty);
            expect(h.navigation.retainedTextureCount, 2);
            await gesture.up();
            released = true;
            await tester.pumpAndSettle();
            expect(h.navigation.leadingPosition, expected);
            expect(h.reports, [expected]);
            expect(h.navigation.retainedTextureCount, 0);
          } finally {
            if (!released) await gesture.cancel();
            await tester.pumpAndSettle();
          }
        },
      );
    }
  }

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

  testWidgets('release and cancel settle from the exact last diagonal shape', (
    tester,
  ) async {
    for (final complete in [false, true]) {
      await tester.pumpWidget(const SizedBox.shrink());
      final h = _Harness();
      await h.mount(tester);
      final start = h.navigation.leadingPosition;
      final bounds = tester.getRect(find.byType(TextViewport)).deflate(20);
      final origin = Offset(bounds.center.dx, bounds.top + bounds.height * .2);
      final gesture = await tester.startGesture(origin);
      var released = false;
      try {
        await gesture.moveBy(const Offset(-20, 0));
        await tester.pump();
        await gesture.moveTo(origin + Offset(-h.size.width * .4, 35));
        await tester.pump(const Duration(milliseconds: 200));
        final held = await _previewPixels(tester);
        if (complete) {
          await gesture.up();
        } else {
          await gesture.cancel();
        }
        released = true;
        await tester.pump();
        expect(await _previewPixels(tester), held);
        expect(h.navigation.leadingPosition, start);
        expect(h.reports, isEmpty);
        await tester.pump(const Duration(milliseconds: 30));
        expect(await _previewPixels(tester), isNot(held));
        await tester.pumpAndSettle();
        expect(h.navigation.leadingPosition, complete ? isNot(start) : start);
        expect(h.reports, hasLength(complete ? 1 : 0));
        expect(h.navigation.retainedTextureCount, 0);
      } finally {
        if (!released) await gesture.cancel();
        await tester.pumpAndSettle();
      }
    }
  });

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
    'drag released during section loading retains its last diagonal raster',
    (tester) async {
      for (final complete in [true, false]) {
        await tester.pumpWidget(const SizedBox.shrink());
        final store = _DelayedStore()..pending = Completer<void>();
        final h = _Harness(store: store);
        await h.mount(tester);
        final start = h.navigation.leadingPosition;
        final bounds = _pageBounds(tester);
        final origin = Offset(
          bounds.left + bounds.width * .75,
          bounds.top + bounds.height * .2,
        );
        final gesture = await tester.startGesture(origin);
        var released = false;
        try {
          await gesture.moveBy(const Offset(-20, 0));
          await tester.pump();
          await gesture.moveTo(
            origin + Offset(-bounds.width * .3, bounds.height * .1),
          );
          await tester.pump();
          await gesture.moveTo(
            origin + Offset(-bounds.width * .5, bounds.height * .15),
          );
          await tester.pump(const Duration(milliseconds: 200));
          if (complete) {
            await gesture.up();
          } else {
            await gesture.cancel();
          }
          released = true;
          expect(h.navigation.leadingPosition, start);
          expect(h.navigation.retainedTextureCount, 0);
          store.pending!.complete();
          await tester.pump();
          await tester.pump();
          final painter = _previewPainter(tester);
          final expected = PaperCurlPainter(
            current: painter.current,
            target: painter.target,
            progress: .5,
            grabY: bounds.height * .2,
            fingerY: bounds.height * .35,
            forward: true,
            fromRight: true,
            paper: const Color(0xfffffbf0),
          );
          expect(
            await _previewPixels(tester),
            (await tester.runAsync(
              () => _rasterPixels(expected, bounds.size),
            ))!,
          );
          expect(h.navigation.leadingPosition, start);
          expect(h.reports, isEmpty);
          await tester.pumpAndSettle();
          expect(
            h.navigation.leadingPosition!.sectionId,
            complete ? 's1' : 's0',
          );
          expect(h.reports, hasLength(complete ? 1 : 0));
          expect(h.navigation.retainedTextureCount, 0);
        } finally {
          if (!released) await gesture.cancel();
          if (!store.pending!.isCompleted) store.pending!.complete();
          await tester.pumpAndSettle();
        }
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
    'curl rasters follow grabs and vertical pulls with mirrored opaque theme paper and continuous exact endpoints',
    (tester) async {
      // Pixel assertions protect geometry and shading without platform font goldens.
      await tester.runAsync(() async {
        const size = Size(240, 160);
        ui.Image page(Color paper, [String? title]) {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder)..drawColor(paper, BlendMode.src);
          if (title != null) {
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
            );
            try {
              text.layout(maxWidth: size.width);
              text.paint(canvas, const Offset(8, 8));
            } finally {
              text.dispose();
            }
          }
          final picture = recorder.endRecording();
          try {
            return picture.toImageSync(240, 160);
          } finally {
            picture.dispose();
          }
        }

        Future<Uint8List> paint(
          ui.Image current,
          ui.Image target,
          Color paper,
          double p, {
          required double grabY,
          required double fingerY,
          bool right = true,
          bool forward = true,
        }) => _rasterPixels(
          PaperCurlPainter(
            current: current,
            target: target,
            progress: p,
            grabY: grabY,
            fingerY: fingerY,
            forward: forward,
            fromRight: right,
            paper: paper,
          ),
          size,
        );

        int exposedBlue(Uint8List pixels, int firstRow, int lastRow) {
          var count = 0;
          for (var y = firstRow; y < lastRow; y++) {
            for (var x = 0; x < 240; x++) {
              final i = (y * 240 + x) * 4;
              if (pixels[i] < 8 && pixels[i + 1] < 8 && pixels[i + 2] > 240) {
                count++;
              }
            }
          }
          return count;
        }

        Uint8List mirror(Uint8List pixels) {
          final result = Uint8List(pixels.length);
          for (var y = 0; y < 160; y++) {
            for (var x = 0; x < 240; x++) {
              final source = (y * 240 + x) * 4;
              final destination = (y * 240 + 239 - x) * 4;
              for (var channel = 0; channel < 4; channel++) {
                result[destination + channel] = pixels[source + channel];
              }
            }
          }
          return result;
        }

        void expectReversePaper(Uint8List pixels, Color paper) {
          final red = (paper.r * 255).round();
          final green = (paper.g * 255).round();
          final blue = (paper.b * 255).round();
          var paperPixels = 0;
          for (var i = 0; i < pixels.length; i += 4) {
            // A region, not a pinned sample: shading and the faint reverse
            // print may tint the paper, but it must not become pure white.
            if ((pixels[i] - red).abs() < 40 &&
                (pixels[i + 1] - green).abs() < 40 &&
                (pixels[i + 2] - blue).abs() < 40 &&
                pixels[i + 2] < 250) {
              paperPixels++;
            }
          }
          expect(paperPixels, greaterThan(240));
        }

        for (final paper in [
          const Color(0xfffffbf0),
          const Color(0xfff2e4c9),
          const Color(0xff202124),
        ]) {
          ui.Image? themedCurrent;
          ui.Image? themedTarget;
          ui.Image? red;
          ui.Image? blue;
          try {
            themedCurrent = page(paper, 'Current');
            themedTarget = page(paper, 'Next');
            final currentPixels = (await themedCurrent.toByteData())!.buffer
                .asUint8List();
            final targetPixels = (await themedTarget.toByteData())!.buffer
                .asUint8List();
            for (final forward in [true, false]) {
              for (final right in [true, false]) {
                for (final height in [.2, .8]) {
                  final grabY = size.height * height;
                  final fingerY = grabY + size.height * .1;
                  for (final p in [0.0, 1.0]) {
                    final endpoint = await paint(
                      themedCurrent,
                      themedTarget,
                      paper,
                      p,
                      grabY: grabY,
                      fingerY: fingerY,
                      right: right,
                      forward: forward,
                    );
                    expect(endpoint, p == 0 ? currentPixels : targetPixels);
                    _expectOpaque(endpoint);
                  }
                  for (final p in [.0001, .9999]) {
                    final near = await paint(
                      themedCurrent,
                      themedTarget,
                      paper,
                      p,
                      grabY: grabY,
                      fingerY: fingerY,
                      right: right,
                      forward: forward,
                    );
                    _expectOpaque(near);
                    expect(
                      _differentPixelFraction(
                        near,
                        p < .5 ? currentPixels : targetPixels,
                      ),
                      lessThanOrEqualTo(.01),
                      reason:
                          'Endpoint continuity: $paper, forward=$forward, '
                          'right=$right, grab=$height, progress=$p',
                    );
                  }
                }
              }
            }

            red = page(const Color(0xffff0000));
            blue = page(const Color(0xff0000ff));
            final upper = await paint(
              red,
              blue,
              paper,
              .3,
              grabY: 32,
              fingerY: 32,
            );
            final center = await paint(
              red,
              blue,
              paper,
              .3,
              grabY: 80,
              fingerY: 80,
            );
            final lower = await paint(
              red,
              blue,
              paper,
              .3,
              grabY: 128,
              fingerY: 128,
            );
            expect(upper, isNot(center));
            expect(lower, isNot(center));
            expect(upper, isNot(lower));
            expect(
              exposedBlue(upper, 0, 40),
              greaterThan(exposedBlue(upper, 120, 160)),
            );
            expect(
              exposedBlue(lower, 0, 40),
              lessThan(exposedBlue(lower, 120, 160)),
            );

            final pulledUp = await paint(
              red,
              blue,
              paper,
              .3,
              grabY: 80,
              fingerY: 32,
            );
            final pulledDown = await paint(
              red,
              blue,
              paper,
              .3,
              grabY: 80,
              fingerY: 128,
            );
            expect(pulledUp, isNot(pulledDown));
            expect(
              exposedBlue(pulledUp, 0, 40),
              lessThan(exposedBlue(pulledDown, 0, 40)),
            );
            expect(
              exposedBlue(pulledUp, 120, 160),
              greaterThan(exposedBlue(pulledDown, 120, 160)),
            );

            final mirrored = await paint(
              red,
              blue,
              paper,
              .3,
              grabY: 32,
              fingerY: 48,
              right: false,
            );
            final diagonal = await paint(
              red,
              blue,
              paper,
              .3,
              grabY: 32,
              fingerY: 48,
            );
            expect(mirrored, isNot(diagonal));
            expect(
              _differentPixelFraction(mirrored, mirror(diagonal), tolerance: 2),
              lessThanOrEqualTo(.01),
            );
            final unfolding = await paint(
              blue,
              red,
              paper,
              .7,
              grabY: 32,
              fingerY: 48,
              forward: false,
            );
            expect(
              _differentPixelFraction(unfolding, diagonal, tolerance: 2),
              lessThanOrEqualTo(.01),
            );
            for (final raster in [
              upper,
              center,
              lower,
              pulledUp,
              pulledDown,
              diagonal,
              mirrored,
              unfolding,
            ]) {
              _expectOpaque(raster);
              expectReversePaper(raster, paper);
            }
          } finally {
            themedCurrent?.dispose();
            themedTarget?.dispose();
            red?.dispose();
            blue?.dispose();
          }
        }
      });
    },
  );
}
