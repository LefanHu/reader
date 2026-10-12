import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/illustrations/illustration_figure.dart';
import 'package:reader/illustrations/illustration_manifest.dart';
import 'package:reader/illustrations/illustration_profile.dart';
import 'package:reader/illustrations/illustration_scene.dart';
import 'package:reader/illustrations/scene_anchor.dart';
import 'package:reader/preferences/reader_settings.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/preferences/reading_theme.dart';
import 'package:reader/reader/illustration_figure_view.dart';
import 'package:reader/reader/reader_screen.dart';
import 'package:reader/text/block_slice.dart';
import 'package:reader/text/layout/section_layout.dart';
import 'package:reader/text/text_block.dart' as text;
import 'package:reader/text/text_position.dart' as text;
import 'package:reader/text/text_section.dart' as text;
import 'package:reader/text/viewport.dart';
import 'package:reader/theme.dart';

import 'fixtures/catalog_book.dart';
import 'support/fonts.dart';
import 'support/illustration_image_fixture.dart';
import 'support/memory_document_store.dart';
import 'support/test_controller.dart';
import 'support/text_viewport_harness.dart';

const _sceneId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _anchor = SceneAnchor(
  href: 's0',
  spineOrdinal: 0,
  paragraphId: 'p1',
  cssSelector: '',
  fallbackProgression: .5,
);

IllustrationScene _scene(
  IllustrationSceneState state, {
  String? path,
  bool regenerating = false,
}) => IllustrationScene(
  id: _sceneId,
  anchor: _anchor,
  state: state,
  localImagePath: path,
  altText: 'A quiet room',
  regenerating: regenerating,
);

// Synchronous IO: widget-test teardown runs under fake async, where awaited
// file operations never complete.
File _imageFile() {
  final dir = Directory.systemTemp.createTempSync('figure-view-');
  addTearDown(() => dir.deleteSync(recursive: true));
  return File('${dir.path}/scene.png')..writeAsBytesSync(illustrationPng());
}

Widget _host(Widget child, {ReadingTheme theme = ReadingTheme.paper}) =>
    MaterialApp(
      theme: buildReaderTheme(theme),
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: const ValueKey('figure-golden'),
            child: SizedBox(width: 360, height: 240, child: child),
          ),
        ),
      ),
    );

IllustrationFigureView _view(IllustrationFigure figure) =>
    IllustrationFigureView(figure: figure, onOpen: () {});

double _progress(WidgetTester tester) => tester
    .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
    .value!;

void main() {
  setUpAll(loadReaderFonts);

  group('figure stages', () {
    test(
      'the furthest stage wins per anchor block and ties pick the smaller ID',
      () {
        final figures = illustrationFigures([
          _scene(IllustrationSceneState.generating),
          IllustrationScene(
            id: 'bbbb',
            anchor: _anchor,
            state: IllustrationSceneState.readyLocked,
          ),
          IllustrationScene(
            id: 'cccc',
            anchor: _anchor,
            state: IllustrationSceneState.readyLocked,
          ),
          IllustrationScene(
            id: 'dddd',
            anchor: const SceneAnchor(
              href: 's0',
              spineOrdinal: 0,
              paragraphId: 'p9',
              cssSelector: '',
              fallbackProgression: 1,
            ),
            state: IllustrationSceneState.hidden,
            localImagePath: '/x.png',
          ),
        ]);
        final figure = figures['s0']!['p1']!;
        expect(figure.stage, IllustrationFigureStage.downloading);
        expect(figure.scene.id, 'bbbb');
        expect(figures['s0']!.containsKey('p9'), isFalse);
      },
    );
  });

  group('IllustrationFigureView', () {
    testWidgets('generating placeholder shows half progress', (tester) async {
      await tester.pumpWidget(
        _host(
          _view(
            IllustrationFigure(
              _scene(IllustrationSceneState.generating),
              IllustrationFigureStage.generating,
            ),
          ),
        ),
      );
      expect(find.text('Illustrating this scene…'), findsOneWidget);
      expect(_progress(tester), .5);
      expect(
        find.bySemanticsLabel(
          'Illustrating this scene… Illustration in progress.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('downloading placeholder shows near-complete progress', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _view(
            IllustrationFigure(
              _scene(IllustrationSceneState.readyLocked),
              IllustrationFigureStage.downloading,
            ),
          ),
        ),
      );
      expect(find.text('Preparing illustration…'), findsOneWidget);
      expect(_progress(tester), .9);
    });

    testWidgets('large accessibility text scales the placeholder down', (
      tester,
    ) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(3)),
          child: _host(
            _view(
              IllustrationFigure(
                _scene(IllustrationSceneState.generating),
                IllustrationFigureStage.generating,
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'ready art is labelled by alt text and a missing file degrades',
      (tester) async {
        final file = _imageFile();
        final ready = IllustrationFigure(
          _scene(IllustrationSceneState.unlocked, path: file.path),
          IllustrationFigureStage.ready,
        );
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(_host(_view(ready)));
        expect(find.bySemanticsLabel('A quiet room'), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);

        file.deleteSync();
        await tester.pumpWidget(_host(_view(ready), theme: ReadingTheme.sepia));
        expect(find.text('Preparing illustration…'), findsOneWidget);
        semantics.dispose();
      },
    );

    testWidgets('regenerating art keeps the image and shows progress', (
      tester,
    ) async {
      final file = _imageFile();
      await tester.pumpWidget(
        _host(
          _view(
            IllustrationFigure(
              _scene(
                IllustrationSceneState.unlocked,
                path: file.path,
                regenerating: true,
              ),
              IllustrationFigureStage.ready,
            ),
          ),
        ),
      );
      expect(find.text('Creating a new version…'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    });

    for (final theme in ReadingTheme.values) {
      testWidgets('placeholder and ready figure ${theme.name} golden', (
        tester,
      ) async {
        final file = _imageFile();
        final figures = [
          IllustrationFigure(
            _scene(IllustrationSceneState.generating),
            IllustrationFigureStage.generating,
          ),
          IllustrationFigure(
            _scene(IllustrationSceneState.unlocked, path: file.path),
            IllustrationFigureStage.ready,
          ),
        ];
        for (final (i, figure) in figures.indexed) {
          await tester.runAsync(() async {
            await tester.pumpWidget(_host(_view(figure), theme: theme));
            if (figure.stage == IllustrationFigureStage.ready) {
              await precacheImage(
                FileImage(file),
                tester.element(find.byType(Scaffold)),
              );
            }
          });
          await tester.pump();
          await expectLater(
            find.byKey(const ValueKey('figure-golden')),
            matchesGoldenFile(
              'goldens/illustration-figure-${theme.name}-${i == 0 ? 'placeholder' : 'ready'}.png',
            ),
          );
        }
      });
    }
  });

  group('viewport figure slots', () {
    for (final mode in [ReadingMode.pageFlip, ReadingMode.scroll]) {
      testWidgets(
        '${mode.name} shows the figure directly after its paragraph',
        (tester) async {
          final h =
              TextViewportHarness(
                  store: MemoryDocumentStore(
                    sections: const [
                      text.TextSection(
                        id: 's0',
                        blocks: [
                          text.TextBlock(id: 'p0', text: 'First paragraph.'),
                          text.TextBlock(id: 'p1', text: 'Anchor paragraph.'),
                          text.TextBlock(id: 'p2', text: 'Third paragraph.'),
                        ],
                      ),
                    ],
                  ),
                )
                ..size = const Size(360, 600)
                ..figureBlocks = {
                  's0': {'p1'},
                }
                ..figureBuilder = ((section, block) =>
                    Container(key: ValueKey('figure-$section-$block')));
          h.settings.value = ReaderSettings(mode: mode);
          await h.mount(tester);
          final figure = tester.getRect(
            find.byKey(const ValueKey('figure-s0-p1')),
          );
          final blocks = tester
              .widgetList<BlockSlice>(find.byType(BlockSlice))
              .toList();
          expect(blocks.map((b) => b.block.block.id), ['p0', 'p1', 'p2']);
          final anchorRect = tester.getRect(find.byType(BlockSlice).at(1));
          final nextRect = tester.getRect(find.byType(BlockSlice).at(2));
          // BlockSlice rects include their bottom padding, so the figure begins
          // where the anchor's slice ends and the next paragraph follows it.
          expect(figure.top, closeTo(anchorRect.bottom, .01));
          expect(nextRect.top, closeTo(figure.bottom + blockGap, .01));
          expect(figure.height, closeTo((360 - 40) / 1.5, .01));
        },
      );
    }
  });

  group('reader screen', () {
    Future<(Directory, File)> mountReader(WidgetTester tester) async {
      final file = _imageFile();
      final book = testBook();
      final controller = await testController(books: [book]);
      addTearDown(controller.dispose);
      controller.illustrations.manifests[book.hash] = IllustrationManifest(
        bookHash: book.hash,
        profile: const IllustrationProfile(
          enabled: true,
          style: 'Ink',
          density: 3,
          providerId: 'openai',
          revision: 1,
          cloudBookId: 'cloud',
        ),
        scenes: [_scene(IllustrationSceneState.unlocked, path: file.path)],
      );
      final store = MemoryDocumentStore(
        sections: const [
          text.TextSection(
            id: 's0',
            blocks: [
              text.TextBlock(id: 'p0', text: 'First paragraph.'),
              text.TextBlock(id: 'p1', text: 'Anchor paragraph.'),
              text.TextBlock(id: 'p2', text: 'Third paragraph.'),
            ],
          ),
          text.TextSection(
            id: 's1',
            blocks: [text.TextBlock(id: 'q0', text: 'Next chapter.')],
          ),
        ],
      );
      await tester.binding.setSurfaceSize(const Size(800, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildReaderTheme(ReadingTheme.paper),
          home: ReaderScreen(
            book: book,
            controller: controller,
            documentStore: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (file.parent, file);
    }

    testWidgets('tapping inline art opens a dialog without Go to scene', (
      tester,
    ) async {
      await mountReader(tester);
      expect(find.byType(IllustrationFigureView), findsOneWidget);
      await tester.tap(find.byType(IllustrationFigureView));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextButton, 'Hide from page'), findsOneWidget);
      expect(find.text('Go to scene'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Close'));
      await tester.pumpAndSettle();
      expect(find.byType(IllustrationFigureView), findsOneWidget);
    });

    testWidgets('hiding removes the figure and the gallery can show it again', (
      tester,
    ) async {
      await mountReader(tester);
      await tester.tap(find.byType(IllustrationFigureView));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Hide from page'));
      await tester.pumpAndSettle();
      expect(find.byType(IllustrationFigureView), findsNothing);

      await tester.tap(find.byTooltip('AI illustrations'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scene illustration'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Show on page'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(IllustrationFigureView), findsOneWidget);
    });

    testWidgets('gallery Go to scene closes the sheet and commits the anchor', (
      tester,
    ) async {
      await mountReader(tester);
      // Leave the anchor chapter so the jump is observable.
      final viewport = tester.widget<TextViewport>(find.byType(TextViewport));
      viewport.navigation.goTo(
        const text.TextPosition(sectionId: 's1', blockId: 'q0'),
      );
      await tester.pumpAndSettle();
      expect(viewport.navigation.leadingPosition!.sectionId, 's1');

      await tester.tap(find.byTooltip('AI illustrations'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scene illustration'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Go to scene'));
      await tester.pumpAndSettle();
      expect(find.text('Illustrated scenes'), findsNothing);
      final position = viewport.navigation.leadingPosition!;
      expect(position.sectionId, 's0');
      expect(position.blockId, 'p1');
      expect(position.offset, 0);
    });
  });
}
