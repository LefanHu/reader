import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'effect_canvas.dart';

// Passive marks for a phrase that can become an illustration. Each loops
// slowly enough to read past, and answers a tap through `frame.activation`.

/// Breathing between [low] and [high] on a [period]-second cycle.
double _breathe(double time, double period, double low, double high) =>
    low + (high - low) * (.5 + .5 * math.sin(time * 2 * math.pi / period));

/// A wavering pen line under the phrase that floods up into a wash on tap.
void inkUnderline(Canvas canvas, EffectFrame frame) {
  final accent = frame.colors.primary;
  final a = frame.activation;
  for (final box in frame.boxes(frame.anchor)) {
    if (a > 0) {
      canvas.drawRect(
        Rect.fromLTRB(
          box.left,
          box.bottom - box.height * a,
          box.right,
          box.bottom,
        ),
        Paint()..color = accent.withValues(alpha: .24 * a),
      );
    }
    final path = Path();
    final y = box.bottom + 1;
    for (var x = box.left; x <= box.right; x += 3) {
      // Two incommensurate waves read as a hand, not a sine.
      final dy =
          math.sin(x * .09 + frame.time * .7) * .9 +
          math.sin(x * .023 + 1.7) * 1.1;
      x == box.left ? path.moveTo(x, y + dy) : path.lineTo(x, y + dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 1.6 + a * .6
        ..color = accent.withValues(
          alpha: math.max(a, _breathe(frame.time, 3.2, .45, .85)),
        ),
    );
  }
  frame.paintText(canvas);
}

/// Gold-leaf lettering with a glint that sweeps across every few seconds.
void giltGlint(Canvas canvas, EffectFrame frame) {
  final boxes = frame.boxes(frame.anchor);
  canvas.save();
  canvas.clipPath(frame.outside(boxes));
  frame.paintText(canvas);
  canvas.restore();

  final gold = frame.colors.primary;
  final shine = Color.lerp(gold, frame.colors.surface, .7)!;
  final edge = Color.lerp(gold, shine, frame.activation * .5)!;
  // The glint crosses in the first 1.4s of each 4.5s cycle, then rests.
  // Activation keeps the leaf lit, as if the page caught the light.
  final sweep = (frame.time % 4.5) / 1.4;
  final w = frame.size.width;
  final x = -w * .3 + sweep * w * 1.6;
  final bounds = Offset.zero & frame.size;
  canvas.saveLayer(bounds, Paint());
  canvas.clipPath(EffectFrame.pathOf(boxes));
  frame.paintText(canvas);
  canvas.drawRect(
    bounds,
    Paint()
      ..blendMode = BlendMode.srcIn
      ..shader = ui.Gradient.linear(
        Offset(x - 60, 0),
        Offset(x + 60, frame.lineHeight * 2),
        [edge, shine, edge],
        [0, .5, 1],
      ),
  );
  canvas.restore();
}

/// An accent-inked first letter with a halo, like a rubricated initial.
void illuminatedInitial(Canvas canvas, EffectFrame frame) {
  final first = frame.text.text!.toPlainText().characters.first.length;
  final glyph = frame.boxes(TextRange(start: 0, end: first)).first;
  final a = frame.activation;
  final center = glyph.center;
  final radius =
      frame.lineHeight * (_breathe(frame.time, 3.6, .85, 1.05) + a * 1.4);
  final accent = frame.colors.primary;
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..shader = ui.Gradient.radial(center, radius, [
        accent.withValues(alpha: .26 + a * .1),
        accent.withValues(alpha: 0),
      ]),
  );
  if (a > 0 && a < 1) {
    // A single ring escapes outward while the halo grows.
    canvas.drawCircle(
      center,
      frame.lineHeight * (.6 + a * 2.4),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = accent.withValues(alpha: .5 * (1 - a)),
    );
  }
  canvas.save();
  canvas.clipPath(frame.outside([glyph]));
  frame.paintText(canvas);
  canvas.restore();
  canvas.save();
  canvas.clipRect(glyph);
  frame.paintTextIn(canvas, accent);
  canvas.restore();
}

/// A soft pigment bloom drifting behind the phrase, deepening on tap.
void watercolorBloom(Canvas canvas, EffectFrame frame) {
  final boxes = frame.boxes(frame.anchor);
  final a = frame.activation;
  final accent = frame.colors.primary;
  for (final (i, box) in boxes.indexed) {
    for (final layer in [0, 1]) {
      final inflate = 4.0 + layer * 5 + a * 4;
      final rect = box.inflate(inflate);
      final path = Path();
      const steps = 36;
      for (var s = 0; s <= steps; s++) {
        final t = s / steps * 2 * math.pi;
        // Radii wobble on slow, per-line phases so blooms never align.
        final wobble =
            1 +
            .08 * math.sin(3 * t + frame.time * .5 + i + layer) +
            .05 * math.sin(5 * t - frame.time * .3 + i * 2);
        final p = Offset(
          rect.center.dx + math.cos(t) * rect.width / 2 * wobble,
          rect.center.dy + math.sin(t) * rect.height / 2 * wobble,
        );
        s == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = accent.withValues(alpha: (layer == 0 ? .14 : .08) + a * .1)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6.0 + layer * 4),
      );
    }
  }
  frame.paintText(canvas);
}

/// A hedera leaf breathing in the margin; a tap runs a line down the passage.
/// Draws left of the passage, inside the screen gutter, so nothing may clip it.
void marginFleuron(Canvas canvas, EffectFrame frame) {
  final box = frame.boxes(frame.anchor).first;
  final accent = frame.colors.primary;
  final a = frame.activation;
  final size = frame.lineHeight * .42;
  final center = Offset(-14, box.center.dy);
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.rotate(-.5 + .12 * math.sin(frame.time * 1.3));
  final leaf = Path()
    ..moveTo(0, size * .55)
    ..cubicTo(-size * 1.1, -size * .1, -size * .5, -size * .9, 0, -size * .35)
    ..cubicTo(size * .5, -size * .9, size * 1.1, -size * .1, 0, size * .55)
    ..close();
  canvas.drawPath(
    leaf,
    Paint()
      ..color = accent.withValues(
        alpha: math.max(a, _breathe(frame.time, 3, .45, .9)),
      ),
  );
  canvas.drawLine(
    Offset(0, size * .5),
    Offset(size * .25, size * 1.05),
    Paint()
      ..color = accent.withValues(alpha: .7)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round,
  );
  canvas.restore();
  if (a > 0) {
    final end = frame.size.height * a;
    canvas.drawLine(
      const Offset(-6, 0),
      Offset(-6, end),
      Paint()
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, end + 1), [
          accent.withValues(alpha: .1),
          accent.withValues(alpha: .7),
        ]),
    );
  }
  frame.paintText(canvas);
}

/// Engraver's dots under the phrase, twinkling left to right; a tap joins them.
void stipple(Canvas canvas, EffectFrame frame) {
  final accent = frame.colors.primary;
  final a = frame.activation;
  final boxes = frame.boxes(frame.anchor);
  final total = boxes.fold(0.0, (sum, box) => sum + box.width);
  var travelled = 0.0;
  for (final box in boxes) {
    final y = box.bottom + 2;
    for (var x = box.left + 2; x < box.right; x += 5) {
      final along = (travelled + x - box.left) / total;
      final wave = math.cos(along * 2 * math.pi - frame.time * 2.4);
      final pulse = math.pow(math.max(0, wave), 6).toDouble();
      canvas.drawCircle(
        Offset(x, y),
        1 + pulse * .7 + a * .4,
        Paint()..color = accent.withValues(alpha: .3 + .7 * math.max(pulse, a)),
      );
    }
    if (a > 0) {
      canvas.drawLine(
        Offset(box.left + 2, y),
        Offset(box.left + 2 + (box.width - 4) * a, y),
        Paint()
          ..color = accent.withValues(alpha: .8)
          ..strokeWidth = 1.4,
      );
    }
    travelled += box.width;
  }
  frame.paintText(canvas);
}

/// Graphite strokes shade in behind the phrase as if a sketch is starting,
/// hold, then lift away; a tap cross-hatches the shading darker.
void pencilHatching(Canvas canvas, EffectFrame frame) {
  final graphite = frame.colors.onSurfaceVariant;
  final boxes = frame.boxes(frame.anchor);
  final a = frame.activation;
  // A 6s cycle: draw for 2.4s, hold, then fade over the last second.
  final cycle = frame.time % 6;
  final drawn = math.max(a, math.min(1.0, cycle / 2.4));
  final fade = math.max(a, math.min(1.0, 6 - cycle));
  final strokes = [
    for (final box in boxes)
      for (var x = box.left - box.height * .6; x < box.right; x += 4.5)
        (box, x),
  ];
  canvas.save();
  canvas.clipPath(
    EffectFrame.pathOf([for (final box in boxes) box.inflate(2)]),
  );
  void hatch(double reach, double alpha, {required bool cross}) {
    for (final (j, (box, x)) in strokes.indexed) {
      if (j / strokes.length >= reach) break;
      // Seeded jitter keeps each stroke still while the next ones arrive.
      final r = math.Random(j * 2 + (cross ? 1 : 0));
      final slant = box.height * .6;
      // Cross strokes lean the other way: they run down rather than up.
      final start = Offset(
        x + r.nextDouble() * 1.6,
        cross ? box.top - 1 : box.bottom + 1,
      );
      final end = Offset(
        x + slant + r.nextDouble() * 1.6,
        cross ? box.bottom + 1 : box.top - 1,
      );
      canvas.drawLine(
        start,
        end,
        Paint()
          ..strokeWidth = .8 + r.nextDouble() * .4
          ..strokeCap = StrokeCap.round
          ..color = graphite.withValues(
            alpha: alpha * (.7 + r.nextDouble() * .3),
          ),
      );
    }
  }

  hatch(drawn, .34 * fade, cross: false);
  if (a > 0) hatch(a, .3, cross: true);
  canvas.restore();
  frame.paintText(canvas);
}

/// A drop of ink falls onto the phrase every few seconds; rings spread along
/// the line and the stain runs outward under the words. A tap lets the ink
/// soak up into a wash.
void inkDrop(Canvas canvas, EffectFrame frame) {
  final accent = frame.colors.primary;
  final boxes = frame.boxes(frame.anchor);
  final first = boxes.first;
  final a = frame.activation;
  final impact = Offset(
    first.left + math.min(first.width / 2, frame.lineHeight * 1.5),
    first.bottom + 1,
  );
  // A 4.2s cycle: fall until .45s, ripple and spread, fade from 3.4s.
  final t = frame.time % 4.2;
  final linger = math.max(a, (1 - (t - 3.4) / .8).clamp(0.0, 1.0));
  final spread = t < .45
      ? 0.0
      : Curves.easeOutCubic.transform(math.min(1, (t - .45) / 1.4));
  final reach = math.max(a, spread);

  for (final (i, box) in boxes.indexed) {
    if (a > 0) {
      canvas.drawRect(
        Rect.fromLTRB(
          box.left,
          box.bottom - box.height * .55 * a,
          box.right,
          box.bottom,
        ),
        Paint()
          ..color = accent.withValues(alpha: .2 * a)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
    }
    // The first line stains outward from the impact; later lines fill in
    // left to right at the same pace.
    final from = i == 0 ? impact.dx - (impact.dx - box.left) * reach : box.left;
    final to = i == 0
        ? impact.dx + (box.right - impact.dx) * reach
        : box.left + box.width * reach;
    if (to > from) {
      canvas.drawLine(
        Offset(from, box.bottom + 1),
        Offset(to, box.bottom + 1),
        Paint()
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round
          ..color = accent.withValues(alpha: .75 * linger),
      );
    }
  }

  if (t < .45 && a == 0) {
    final fall = Curves.easeIn.transform(t / .45);
    final y = impact.dy - frame.lineHeight * 1.6 * (1 - fall);
    final drop = Path()
      ..moveTo(impact.dx, y - 6)
      ..quadraticBezierTo(impact.dx + 3, y - 1, impact.dx, y + 1.5)
      ..quadraticBezierTo(impact.dx - 3, y - 1, impact.dx, y - 6)
      ..close();
    canvas.drawPath(drop, Paint()..color = accent.withValues(alpha: fall));
  }
  for (final delay in [0.0, .25, .5]) {
    final age = (t - .45 - delay) / 1.6;
    if (age <= 0 || age >= 1) continue;
    final width = frame.lineHeight * 5 * Curves.easeOut.transform(age);
    canvas.drawOval(
      Rect.fromCenter(center: impact, width: width, height: width * .18),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..color = accent.withValues(alpha: .6 * (1 - age)),
    );
  }
  frame.paintText(canvas);
}
