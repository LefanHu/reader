import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'effect_canvas.dart';

/// The showpiece hint. At rest the phrase is gilt with a glint travelling
/// letter to letter while motes of gold dust rise off it. A tap conjures the
/// picture: letters lift and tumble in a staggered wave, sparks burst from the
/// phrase, a gold frame draws itself around it with corner jewels, and the
/// letters fall back with a bounce, set in gold leaf under a lasting glow.
///
/// The tap response is choreographed over `frame.activation` in overlapping
/// phases; the canvas runs it over 2.4s.
void conjure(Canvas canvas, EffectFrame frame) {
  final colors = frame.colors;
  final gold = colors.primary;
  final shine = Color.lerp(gold, colors.surface, .55)!;
  final a = frame.activation;
  double phase(double begin, double end) =>
      ((a - begin) / (end - begin)).clamp(0.0, 1.0);

  final boxes = frame.boxes(frame.anchor);
  final bounds = boxes.reduce((x, y) => x.expandToInclude(y));
  final glyphs = frame.glyphs(frame.anchor);

  // Glow that the settled gold sits in.
  final glow = phase(.5, 1);
  if (glow > 0) {
    for (final box in boxes) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(box.inflate(5), const Radius.circular(6)),
        Paint()
          ..color = gold.withValues(alpha: .14 * glow)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
      );
    }
  }

  canvas.save();
  canvas.clipPath(frame.outside(boxes));
  frame.paintText(canvas);
  canvas.restore();

  final ink = colors.onSurface;
  for (final (i, glyph) in glyphs.indexed) {
    final r = math.Random(i);
    final stagger = i / glyphs.length;
    // Rise in a wave across the phrase, then fall back in the same order.
    final rise = Curves.easeOutCubic.transform(
      ((a - stagger * .2) / .25).clamp(0.0, 1.0),
    );
    final fall = Curves.bounceOut.transform(
      ((a - .55 - stagger * .12) / .3).clamp(0.0, 1.0),
    );
    final airborne = rise * (1 - fall);
    final spin = (r.nextDouble() - .5) * 2.6;
    final bob = math.sin(frame.time * 5 + i * .7) * 3;
    // At rest a glint walks along the letters every couple of seconds.
    final glint = math.pow(
      math.max(0, math.cos(i * .35 - frame.time * 2.2)),
      12,
    );
    final settled = Color.lerp(ink, gold, .55 + .45 * fall)!;
    frame.paintGlyph(
      canvas,
      glyph,
      shift: Offset(
        (r.nextDouble() - .5) * 10 * airborne,
        -(frame.lineHeight * .75 + bob) * airborne,
      ),
      turn: spin * airborne,
      scale: 1 + .25 * airborne,
      color: Color.lerp(settled, shine, math.max(airborne, glint * .7))!,
    );
  }

  // Sparks radiate from the phrase while the letters are in the air.
  final burst = phase(.28, .62);
  if (burst > 0 && burst < 1) {
    final travel = Curves.easeOutCubic.transform(burst);
    for (var k = 0; k < 32; k++) {
      final r = math.Random(100 + k);
      final angle = k / 32 * 2 * math.pi + r.nextDouble() * .3;
      final reach = (bounds.width * .35 + 24 + r.nextDouble() * 40) * travel;
      final direction = Offset(math.cos(angle), math.sin(angle) * .6);
      final head = bounds.center + direction * reach;
      final tail = bounds.center + direction * reach * .78;
      canvas.drawLine(
        tail,
        head,
        Paint()
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.round
          ..color = (k.isEven ? gold : shine).withValues(alpha: 1 - burst),
      );
    }
  }

  // The frame traces the phrase's own shape, not its bounding box, so it
  // never encloses neighbouring words on a wrapped line. Line boxes are
  // inflated enough to overlap and merge into one contour.
  final draw = Curves.easeInOutCubic.transform(phase(.3, .78));
  if (draw > 0) {
    final pad = math.max(8.0, (frame.lineHeight - boxes.first.height) / 2 + 2);
    final frames = [
      for (final box in boxes)
        Rect.fromLTRB(
          box.left - 8,
          box.top - pad,
          box.right + 8,
          box.bottom + pad,
        ),
    ];
    var outline = Path()
      ..addRRect(
        RRect.fromRectAndRadius(frames.first, const Radius.circular(8)),
      );
    for (final rect in frames.skip(1)) {
      outline = Path.combine(
        PathOperation.union,
        outline,
        Path()
          ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(8))),
      );
    }
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..color = gold;
    for (final metric in outline.computeMetrics()) {
      canvas.drawPath(metric.extractPath(0, metric.length * draw), paint);
    }
    // Jewels pop in where the phrase begins and ends.
    final jewel = Curves.elasticOut.transform(phase(.72, .95));
    if (jewel > 0) {
      for (final corner in [frames.first.topLeft, frames.last.bottomRight]) {
        final size = 4.5 * jewel;
        canvas.drawPath(
          Path()
            ..moveTo(corner.dx, corner.dy - size)
            ..lineTo(corner.dx + size, corner.dy)
            ..lineTo(corner.dx, corner.dy + size)
            ..lineTo(corner.dx - size, corner.dy)
            ..close(),
          Paint()..color = gold,
        );
      }
    }
  }

  // Gold dust drifts up off the phrase; more of it once conjured.
  final motes = 10 + (14 * a).round();
  for (var k = 0; k < motes; k++) {
    final r = math.Random(k * 7 + 3);
    final period = 2.6 + r.nextDouble() * 1.6;
    final age = ((frame.time + r.nextDouble() * period) / period) % 1;
    final rise = frame.lineHeight * (1.2 + a * .8) * age;
    final source = boxes[r.nextInt(boxes.length)];
    final center = Offset(
      source.left + r.nextDouble() * source.width + math.sin(age * 6 + k) * 5,
      source.bottom - r.nextDouble() * source.height - rise,
    );
    final alpha = math.sin(math.pi * age) * (.45 + .3 * a);
    final radius = .8 + r.nextDouble() * 1.3;
    canvas.drawCircle(
      center,
      radius * 2.4,
      Paint()
        ..shader = ui.Gradient.radial(center, radius * 2.4, [
          shine.withValues(alpha: alpha * .5),
          shine.withValues(alpha: 0),
        ]),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = gold.withValues(alpha: alpha),
    );
  }
}
