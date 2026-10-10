import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/text/page_curl.dart';
import 'package:reader/text/viewport.dart';

/// Rasterizes a live preview without taking ownership of viewport textures.
Future<Uint8List> previewPixels(WidgetTester tester) async {
  final finder = find.byWidgetPredicate(
    (widget) => widget is CustomPaint && widget.painter is PaperCurlPainter,
  );
  final painter = tester.widget<CustomPaint>(finder).painter!;
  return (await tester.runAsync(
    () => rasterPixels(painter, tester.getSize(finder)),
  ))!;
}

/// Rasterizes a borrowed painter, disposing only the new picture and image.
Future<Uint8List> rasterPixels(CustomPainter painter, Size size) async {
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

/// Returns the viewport interior after its original page padding.
Rect pageBounds(WidgetTester tester) {
  final viewport = tester.getRect(find.byType(TextViewport));
  return Rect.fromLTRB(
    viewport.left + 20,
    viewport.top + 12,
    viewport.right - 20,
    viewport.bottom - 12,
  );
}

/// Borrows the single live preview painter without owning its textures.
PaperCurlPainter previewPainter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((widget) => widget.painter)
    .whereType<PaperCurlPainter>()
    .single;

/// Asserts that every RGBA pixel has fully opaque alpha.
void expectOpaque(Uint8List pixels) {
  var transparentPixels = 0;
  for (var i = 3; i < pixels.length; i += 4) {
    if (pixels[i] != 255) transparentPixels++;
  }
  expect(transparentPixels, 0, reason: 'Every curl pixel must be opaque');
}

/// Counts differing pixels with the original per-channel tolerance.
double differentPixelFraction(Uint8List a, Uint8List b, {int tolerance = 0}) {
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
