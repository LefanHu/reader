import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/books.dart';
import 'package:reader/library.dart';
import 'package:reader/reader.dart';

Future<void> mount(
  WidgetTester tester,
  ReaderController controller,
  Size size, {
  double scale = 1,
  bool reader = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: reader
          ? ReaderScreen(book: books.first, controller: controller)
          : LibraryScreen(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Library search, filters, sorting, and navigation work', (
    tester,
  ) async {
    final controller = ReaderController();
    addTearDown(controller.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, controller, const Size(1024, 1100));
    expect(find.text('Your library'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'samuel');
    await tester.pumpAndSettle();
    expect(find.text('A Field Guide to Quiet'), findsOneWidget);
    expect(find.text('An Atlas of Small Places'), findsNothing);
    await tester.enterText(find.byType(TextField), 'no match');
    await tester.pumpAndSettle();
    expect(find.text('No books here yet'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('Finished').first);
    await tester.pumpAndSettle();
    expect(find.text('No books here yet'), findsOneWidget);
    final book = books[1];
    controller.save(
      book,
      book.chapters.length - 1,
      book.chapters.last.text.length,
    );
    await tester.pumpAndSettle();
    expect(find.text('A Field Guide to Quiet'), findsOneWidget);
    await tester.tap(find.text('All books'));
    await tester.tap(find.byTooltip('Sort books'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Title A–Z').last);
    await tester.pumpAndSettle();
    final titles = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .toList();
    expect(
      titles.indexOf('A Field Guide to Quiet'),
      lessThan(titles.indexOf('An Atlas of Small Places')),
    );
    await tester.tap(find.text('Start reading'));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Back to library'));
    await tester.pumpAndSettle();
    expect(find.text('Resume reading'), findsOneWidget);
  });

  testWidgets('Modes, typography, resize, and resume retain the passage', (
    tester,
  ) async {
    final controller = ReaderController()..open(books.first);
    addTearDown(controller.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, controller, const Size(390, 844));
    await tester.tap(find.text('Resume reading'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('chapter-scroll')),
      const Offset(0, -350),
    );
    await tester.pumpAndSettle();
    final anchor = controller.position(books.first).offset;
    expect(anchor, greaterThan(0));
    await tester.tap(find.byTooltip('Reading settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pages'));
    await tester.pumpAndSettle();
    expect(controller.mode, ReadingMode.pages);
    await tester.tap(find.text('Sans serif'));
    await tester.pumpAndSettle();
    expect(controller.serif, isFalse);
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(controller.theme, ReadingTheme.dark);
    await tester.tap(find.byTooltip('Close settings'));
    await tester.pumpAndSettle();
    expect(controller.position(books.first).offset, anchor);
    expect(find.byKey(const ValueKey('chapter-pages')), findsOneWidget);
    // Measure the effective rendered style, including inherited theme values.
    // This catches extra lines caused by a mismatch with pagination metrics.
    final pageText = find
        .descendant(of: find.byType(PageView), matching: find.byType(Text))
        .first;
    final text = tester.widget<Text>(pageText);
    final effectiveStyle = DefaultTextStyle.of(tester.element(pageText)).style
        .merge(text.style);
    final painter = TextPainter(
      text: TextSpan(text: text.data, style: effectiveStyle),
      textDirection: TextDirection.ltr,
      textScaler: text.textScaler!,
    )..layout(maxWidth: tester.getSize(pageText).width);
    expect(
      painter.height,
      lessThanOrEqualTo(tester.getSize(find.byType(PageView)).height),
    );
    painter.dispose();

    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(controller.position(books.first).offset, anchor);
    expect(tester.takeException(), isNull);
    controller.configure(fontSize: 26);
    await tester.pumpAndSettle();
    expect(controller.position(books.first).offset, anchor);
    controller.configure(mode: ReadingMode.scroll);
    await tester.pumpAndSettle();
    expect(controller.position(books.first).offset, anchor);
    await tester.tap(find.byTooltip('Hide reading controls'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back to library'), findsNothing);
    await tester.tap(find.byTooltip('Show reading controls'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back to library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resume reading'));
    await tester.pumpAndSettle();
    expect(controller.position(books.first).offset, anchor);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Page swipes, chapter boundaries, and completion update the library',
    (tester) async {
      final controller = ReaderController()
        ..open(books.first)
        ..configure(mode: ReadingMode.pages);
      addTearDown(controller.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, controller, const Size(390, 844));
      await tester.tap(find.text('Resume reading'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == 'Previous chapter',
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.drag(find.byType(PageView), const Offset(-350, 0));
      await tester.pumpAndSettle();
      expect(controller.position(books.first).offset, greaterThan(0));
      await tester.tap(find.byTooltip('Previous page'));
      await tester.pumpAndSettle();
      expect(controller.position(books.first).offset, 0);
      await tester.tap(find.byTooltip('Choose chapter'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('The house at the edge').last);
      await tester.pumpAndSettle();
      expect(controller.position(books.first).offset, 0);
      expect(
        tester.widget<PageView>(find.byType(PageView)).controller!.page,
        0,
      );
      await tester.tap(find.byTooltip('Choose chapter'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('What the water keeps'));
      await tester.pumpAndSettle();
      expect(controller.position(books.first).chapter, 2);
      while (find.byTooltip('Next page').evaluate().isNotEmpty) {
        await tester.tap(find.byTooltip('Next page'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('Finish book'));
      await tester.pumpAndSettle();
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(controller.progress(books.first), 1);
    },
  );

  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(768, 1024),
    const Size(1024, 768),
    const Size(375, 720),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Library and reader fit $size at text scale $scale', (
        tester,
      ) async {
        final controller = ReaderController()..open(books.first);
        addTearDown(controller.dispose);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await mount(tester, controller, size, scale: scale);
        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await mount(tester, controller, size, scale: scale, reader: true);
        expect(tester.takeException(), isNull);
        controller.configure(mode: ReadingMode.pages, fontSize: 30);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Reading settings'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
