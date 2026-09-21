import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/main.dart';

void main() {
  testWidgets('Render phone and tablet review images', (tester) async {
    for (final entry in {'Lora': 'Lora', 'DM Sans': 'DMSans'}.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(rootBundle.load('assets/fonts/${entry.value}.ttf'));
      await loader.load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final key = GlobalKey();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/reader-$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpWidget(RepaintBoundary(key: key, child: const MyApp()));
    await capture('phone-library');
    tester.view.physicalSize = const Size(1024, 768);
    await capture('tablet-library');
    await tester.tap(find.text('Start reading'));
    await capture('tablet-reader');
    tester.view.physicalSize = const Size(390, 844);
    await capture('phone-reader');
    await tester.tap(find.byTooltip('Reading settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pages'));
    await capture('phone-settings');
    await tester.tap(find.byTooltip('Close settings'));
    await capture('phone-pages');
  });
}
