import 'dart:async';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/app/reader_controller.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/importing/book_importer.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/preferences/reading_theme.dart';
import 'package:reader/reader/reader_screen.dart';
import 'package:reader/text/text_block.dart' as text;
import 'package:reader/text/text_section.dart' as text;
import 'package:reader/text/viewport.dart';

import 'fixtures/catalog_book.dart';
import 'support/fake_illustration_api.dart';
import 'support/fake_picker.dart';
import 'support/fake_text_indexer.dart';
import 'support/fake_word_counter.dart';
import 'support/memory_catalog_store.dart';
import 'support/memory_illustration_store.dart';
import 'support/memory_settings_store.dart';
import 'support/memory_document_store.dart';
import 'support/test_controller.dart';

/// Real reader shell with enough text to observe scrolling and page positions.
Future<ReaderController> _mount(
  WidgetTester tester, {
  ReadingMode mode = ReadingMode.scroll,
  bool reducedMotion = false,
}) async {
  final book = testBook();
  final controller = await testController(books: [book]);
  addTearDown(controller.dispose);
  await controller.preferences.configure(mode: mode);
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

/// Holds only explicitly armed catalog writes, so mounting cannot deadlock.
class _GatedCatalogStore extends MemoryCatalogStore {
  _GatedCatalogStore(super.initial);

  Completer<void>? _gate;
  int heldSaves = 0;

  void arm() {
    heldSaves = 0;
    _gate = Completer<void>();
  }

  void release() {
    final gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<void> save(List<CatalogBook> value) async {
    final gate = _gate;
    if (gate != null) {
      heldSaves++;
      await gate.future;
    }
    await super.save(value);
  }
}

/// A real pushed Reader route above a sentinel, with optional held persistence.
class _RoutedReader {
  _RoutedReader(this.controller, this.store, this.navigator);

  final ReaderController controller;
  final _GatedCatalogStore store;
  final GlobalKey<NavigatorState> navigator;

  static Future<_RoutedReader> mount(
    WidgetTester tester, {
    ReadingMode mode = ReadingMode.scroll,
    bool rtl = false,
    bool gated = false,
  }) async {
    // At phone width the viewport reaches the screen edge: x=19 must remain
    // outside its padded page hit targets, including RTL curl previews.
    await tester.binding.setSurfaceSize(const Size(390, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final book = testBook();
    final store = _GatedCatalogStore([book]);
    final controller = gated
        ? ReaderController(
            catalogStore: store,
            settingsStore: MemorySettingsStore(),
            importer: BookImporter(
              root: Directory('${Directory.systemTemp.path}/reader_test'),
            ),
            picker: FakePicker(const []),
            illustrationStore: MemoryIllustrationStore(),
            textIndexer: FakeTextIndexer(),
            wordCounter: FakeWordCounter(),
            illustrationApi: FakeIllustrationApi(),
          )
        : await testController(books: [book]);
    if (gated) await controller.initialize();
    final navigator = GlobalKey<NavigatorState>();
    addTearDown(() async {
      store.release();
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.flush();
      controller.dispose();
    });
    await controller.preferences.configure(mode: mode);
    final documents = MemoryDocumentStore(
      sections: [
        text.TextSection(
          id: 's0',
          blocks: [
            for (var i = 0; i < 8; i++)
              text.TextBlock(
                id: 'p$i',
                text: rtl
                    ? 'العربية نص طويل للقراءة واختبار الصفحات English 中文 ' * 80
                    : 'English 中文 العربية हिन्दी e\u0301 👩🏽‍🚀 ' * 80,
              ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Reader route root')),
      ),
    );
    navigator.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Directionality(
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          child: ReaderScreen(
            book: book,
            controller: controller,
            documentStore: documents,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return _RoutedReader(controller, store, navigator);
  }
}

/// Sends a real pointer sequence, cancelling only while it remains active.
Future<void> _readerDrag(
  WidgetTester tester,
  Offset origin,
  Offset displacement, {
  bool cancel = false,
  Future<void> Function()? held,
}) async {
  final gesture = await tester.startGesture(origin);
  var active = true;
  try {
    await gesture.moveBy(displacement * .25);
    await tester.pump();
    await gesture.moveBy(displacement * .75);
    await tester.pump(const Duration(milliseconds: 100));
    if (held != null) await held();
    if (cancel) {
      await gesture.cancel();
    } else {
      await gesture.up();
    }
    active = false;
    await tester.pumpAndSettle();
  } finally {
    if (active) await gesture.cancel();
  }
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
  for (final mode in ReadingMode.values) {
    for (final hidden in [false, true]) {
      for (final rtl in mode == ReadingMode.scroll ? [false] : [false, true]) {
        testWidgets(
          '${mode.name} ${hidden ? 'hidden' : 'visible'} '
          '${rtl ? 'RTL' : 'LTR'} routed edge Back preserves complete anchor',
          (tester) async {
            final fixture = await _RoutedReader.mount(
              tester,
              mode: mode,
              rtl: rtl,
            );
            final navigation = tester
                .widget<TextViewport>(find.byType(TextViewport))
                .navigation;
            navigation.next();
            await tester.pumpAndSettle();
            final anchor = navigation.leadingPosition;
            expect(anchor, isNotNull);
            expect(
              fixture.controller.catalog.books.single.lastPosition,
              anchor,
            );
            if (hidden) {
              await tester.tapAt(tester.getCenter(find.byType(TextViewport)));
              await tester.pumpAndSettle();
              expect(find.byTooltip('Show reading controls'), findsOneWidget);
            }
            final origin = Offset(
              19,
              tester.getCenter(find.byType(TextViewport)).dy,
            );
            Future<void> unchanged() async {
              expect(find.byType(ReaderScreen), findsOneWidget);
              expect(navigation.leadingPosition, anchor);
              expect(
                fixture.controller.catalog.books.single.lastPosition,
                anchor,
              );
            }

            await _readerDrag(
              tester,
              origin,
              const Offset(100, 0),
              cancel: true,
              held: unchanged,
            );
            await unchanged();
            await _readerDrag(
              tester,
              origin,
              const Offset(100, 0),
              held: unchanged,
            );
            expect(find.byType(ReaderScreen), findsNothing);
            expect(find.text('Reader route root'), findsOneWidget);
            expect(
              fixture.controller.catalog.books.single.lastPosition,
              anchor,
            );
            expect(
              (await fixture.controller.catalog.store.load())
                  .single
                  .lastPosition,
              anchor,
            );
          },
        );
      }
    }
    for (final rtl in mode == ReadingMode.scroll ? [false] : [false, true]) {
      testWidgets(
        '${mode.name} ${rtl ? 'RTL' : 'LTR'} interior gesture navigates content',
        (tester) async {
          final fixture = await _RoutedReader.mount(
            tester,
            mode: mode,
            rtl: rtl,
          );
          final navigation = tester
              .widget<TextViewport>(find.byType(TextViewport))
              .navigation;
          final before = navigation.leadingPosition;
          final bounds = tester.getRect(find.byType(TextViewport));
          final scrollable = find.descendant(
            of: find.byType(TextViewport),
            matching: find.byType(Scrollable),
          );
          final scrollBefore = mode == ReadingMode.scroll
              ? tester.state<ScrollableState>(scrollable.first).position.pixels
              : null;
          if (mode == ReadingMode.pages) {
            // Pages uses fling velocity; curl and edge Back instead use travel.
            await tester.flingFrom(
              bounds.center,
              Offset(bounds.width * (rtl ? .7 : -.7), 0),
              800,
            );
            await tester.pumpAndSettle();
          } else {
            await _readerDrag(
              tester,
              bounds.center,
              mode == ReadingMode.scroll
                  ? const Offset(0, -250)
                  : Offset(bounds.width * (rtl ? .7 : -.7), 0),
              held: mode == ReadingMode.pageFlip
                  ? () async {
                      expect(navigation.leadingPosition, before);
                      expect(
                        fixture.controller.catalog.books.single.lastPosition,
                        before,
                      );
                    }
                  : null,
            );
          }
          expect(find.byType(ReaderScreen), findsOneWidget);
          if (mode == ReadingMode.scroll) {
            expect(
              tester.state<ScrollableState>(scrollable.first).position.pixels,
              greaterThan(scrollBefore!),
            );
          }
          expect(navigation.leadingPosition, isNot(before));
          expect(
            fixture.controller.catalog.books.single.lastPosition,
            navigation.leadingPosition,
          );
        },
      );
    }
  }

  for (final coverBeforeDown in [false, true]) {
    testWidgets(
      'cover ${coverBeforeDown ? 'before DOWN' : 'before UP'} prevents Reader edge exit',
      (tester) async {
        final fixture = await _RoutedReader.mount(tester);
        final navigation = tester
            .widget<TextViewport>(find.byType(TextViewport))
            .navigation;
        navigation.next();
        await tester.pumpAndSettle();
        final anchor = navigation.leadingPosition;
        final origin = Offset(
          1,
          tester.getCenter(find.byType(TextViewport)).dy,
        );
        Future<void> cover() async {
          fixture.navigator.currentState!.push<void>(
            MaterialPageRoute<void>(
              builder: (_) =>
                  const Scaffold(body: Text('Covering active gesture')),
            ),
          );
          await tester.pumpAndSettle();
        }

        if (coverBeforeDown) await cover();
        await _readerDrag(
          tester,
          origin,
          const Offset(100, 0),
          held: coverBeforeDown ? null : cover,
        );
        expect(find.text('Covering active gesture'), findsOneWidget);
        expect(find.byType(ReaderScreen, skipOffstage: false), findsOneWidget);
        expect(navigation.leadingPosition, anchor);
        expect(fixture.controller.catalog.books.single.lastPosition, anchor);
        fixture.navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.byType(ReaderScreen), findsOneWidget);
        expect(navigation.leadingPosition, anchor);
      },
    );
  }

  testWidgets('edge exit waits for one flush despite competing toolbar Back', (
    tester,
  ) async {
    final fixture = await _RoutedReader.mount(tester, gated: true);
    final navigation = tester
        .widget<TextViewport>(find.byType(TextViewport))
        .navigation;
    navigation.next();
    await tester.pumpAndSettle();
    final anchor = navigation.leadingPosition;
    fixture.store.arm();
    await _readerDrag(
      tester,
      Offset(1, tester.getCenter(find.byType(TextViewport)).dy),
      const Offset(100, 0),
    );
    expect(fixture.store.heldSaves, 1);
    expect(find.byType(ReaderScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Back to library'));
    await tester.pump();
    expect(fixture.store.heldSaves, 1);
    expect(find.byType(ReaderScreen), findsOneWidget);
    fixture.store.release();
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsNothing);
    expect(find.text('Reader route root'), findsOneWidget);
    expect((await fixture.store.load()).single.lastPosition, anchor);
  });

  testWidgets(
    'covering route during flush preserves both routes and allows retry',
    (tester) async {
      final fixture = await _RoutedReader.mount(tester, gated: true);
      final navigation = tester
          .widget<TextViewport>(find.byType(TextViewport))
          .navigation;
      navigation.next();
      await tester.pumpAndSettle();
      final anchor = navigation.leadingPosition;
      fixture.store.arm();
      await _readerDrag(
        tester,
        Offset(1, tester.getCenter(find.byType(TextViewport)).dy),
        const Offset(100, 0),
      );
      expect(fixture.store.heldSaves, 1);
      fixture.navigator.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Covering Reader route')),
        ),
      );
      await tester.pumpAndSettle();
      fixture.store.release();
      await tester.pumpAndSettle();
      expect(find.text('Covering Reader route'), findsOneWidget);
      expect(find.byType(ReaderScreen, skipOffstage: false), findsOneWidget);
      expect((await fixture.store.load()).single.lastPosition, anchor);
      fixture.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(navigation.leadingPosition, anchor);
      await tester.tap(find.byTooltip('Back to library'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsNothing);
      expect(find.text('Reader route root'), findsOneWidget);
      expect((await fixture.store.load()).single.lastPosition, anchor);
    },
  );

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
      expect(controller.preferences.settings.mode, ReadingMode.scroll);
      expect(controller.preferences.settings.serif, isFalse);
      expect(controller.preferences.settings.theme, ReadingTheme.dark);
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
          expect(controller.catalog.books.single.lastPosition, anchor);
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
