import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/text/page_curl.dart';

import 'fixtures/text_documents.dart';
import 'support/page_curl_raster.dart';

void main() {
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
                text: '$title $multilingualText',
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
        }) => rasterPixels(
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
                    expectOpaque(endpoint);
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
                    expectOpaque(near);
                    expect(
                      differentPixelFraction(
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
              differentPixelFraction(mirrored, mirror(diagonal), tolerance: 2),
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
              differentPixelFraction(unfolding, diagonal, tolerance: 2),
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
              expectOpaque(raster);
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
