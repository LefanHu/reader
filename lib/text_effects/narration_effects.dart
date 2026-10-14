import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'effect_canvas.dart';

// Marks following the spoken word. Each reads only `wordClock`, so the real
// reader can drive them from narration word timings instead of the demo clock.

/// Eased progress through the first [portion] of the current word.
double _settle(EffectFrame frame, [double portion = .35]) =>
    Curves.easeOutCubic.transform(math.min(1, frame.wordProgress / portion));

/// Unspoken words wait in the muted color and fill with ink as they are read.
void inking(Canvas canvas, EffectFrame frame) {
  final ink = frame.colors.onSurface;
  frame.paintTextIn(
    canvas,
    frame.colors.onSurfaceVariant.withValues(alpha: .55),
  );
  final spokenCount = frame.finished ? frame.words.length : frame.word;
  final spoken = [
    for (var i = 0; i < spokenCount; i++) ...frame.boxes(frame.words[i]),
  ];
  canvas.save();
  canvas.clipPath(EffectFrame.pathOf(spoken));
  frame.paintTextIn(canvas, ink);
  canvas.restore();
  if (frame.finished) return;

  // The current word fills behind a soft leading edge.
  final rect = frame.wordRect(frame.word);
  final edge = frame.wordProgress * 1.3;
  canvas.saveLayer(rect, Paint());
  frame.paintTextIn(canvas, ink);
  final rtl = frame.text.textDirection == TextDirection.rtl;
  canvas.drawRect(
    rect,
    Paint()
      ..blendMode = BlendMode.dstIn
      ..shader = ui.Gradient.linear(
        rtl ? rect.centerRight : rect.centerLeft,
        rtl ? rect.centerLeft : rect.centerRight,
        [Colors.black, Colors.transparent],
        [math.max(0, edge - .3), math.min(1, edge)],
      ),
  );
  canvas.restore();
}

/// A warm pool of light follows the voice; the rest of the page falls dim.
void lamplight(Canvas canvas, EffectFrame frame) {
  final from = frame.wordRect(frame.word - 1).center;
  final to = frame.wordRect(frame.word).center;
  final center = Offset.lerp(from, to, _settle(frame, .5))!;
  final radius = frame.lineHeight * 2.6;
  // The pool stays on the page: it must not light the labels around it.
  canvas.save();
  canvas.clipRect((Offset.zero & frame.size).inflate(frame.lineHeight * .25));
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..shader = ui.Gradient.radial(center, radius, [
        frame.colors.primary.withValues(alpha: .2),
        frame.colors.primary.withValues(alpha: 0),
      ]),
  );
  canvas.restore();
  frame.paintText(canvas);
  // Dimming is paper laid over the text, so it works on every theme.
  final bounds = (Offset.zero & frame.size).inflate(4);
  canvas.drawRect(
    bounds,
    Paint()
      ..shader = ui.Gradient.radial(
        center,
        radius * 1.6,
        [
          frame.colors.surface.withValues(alpha: 0),
          frame.colors.surface.withValues(alpha: .55),
        ],
        [.35, 1],
      ),
  );
}

/// A slim rule glides beneath the spoken word, shrinking out at line ends and
/// growing in on the next line rather than cutting diagonally across text.
void readingRule(Canvas canvas, EffectFrame frame) {
  frame.paintText(canvas);
  final from = frame.wordRect(frame.word - 1);
  final to = frame.wordRect(frame.word);
  final t = _settle(frame, .45);
  final Rect rule;
  if (frame.word == 0 || (from.bottom - to.bottom).abs() < 1) {
    rule = Rect.lerp(from, to, t)!;
  } else if (t < .5) {
    final k = 1 - t * 2;
    rule = Rect.fromLTRB(
      from.right - from.width * k,
      from.top,
      from.right,
      from.bottom,
    );
  } else {
    final k = t * 2 - 1;
    rule = Rect.fromLTRB(to.left, to.top, to.left + to.width * k, to.bottom);
  }
  final y = rule.bottom + 2;
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTRB(rule.left, y, rule.right, y + 2.5),
      const Radius.circular(1.25),
    ),
    Paint()..color = frame.colors.primary,
  );
}

/// The spoken word rises a few pixels and settles, casting a faint shadow.
void lift(Canvas canvas, EffectFrame frame) {
  if (frame.finished) {
    frame.paintText(canvas);
    return;
  }
  final rect = frame.wordRect(frame.word);
  final p = frame.wordProgress;
  // Quick rise, slower settle, back on the baseline before the next word.
  final height = math.sin(math.pi * math.min(1, p * 1.4)) * 3;
  canvas.save();
  canvas.clipPath(frame.outside([rect]));
  frame.paintText(canvas);
  canvas.restore();
  canvas.drawOval(
    Rect.fromCenter(
      center: rect.bottomCenter.translate(0, 1),
      width: rect.width * .9,
      height: 3,
    ),
    Paint()
      ..color = frame.colors.onSurface.withValues(alpha: .1 * height / 3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
  );
  canvas.save();
  canvas.clipRect(rect.shift(Offset(0, -height)).inflate(1));
  canvas.translate(0, -height);
  frame.paintTextIn(
    canvas,
    Color.lerp(frame.colors.onSurface, frame.colors.primary, height / 3)!,
  );
  canvas.restore();
}

/// A highlighter stroke with torn ends draws across each word, then fades.
void markerStroke(Canvas canvas, EffectFrame frame) {
  final accent = frame.colors.primary;
  // Translucent accent reads weaker on dark paper, so it needs more ink.
  final strength = frame.colors.brightness == Brightness.dark ? .45 : .3;
  for (var i = math.max(0, frame.word - 4); i <= frame.word; i++) {
    final age = frame.wordClock - i - 1;
    final alpha = strength * (1 - age / 3).clamp(0, 1);
    if (alpha <= 0) continue;
    final reach = i < frame.word ? 1.0 : _settle(frame, .5);
    final rect = frame.wordRect(i).inflate(2);
    // Per-word jitter is seeded by index so ends stay put while visible.
    final r = math.Random(i);
    double jag() => r.nextDouble() * 3 - 1.5;
    final top = rect.top + rect.height * .32;
    final bottom = rect.bottom - rect.height * .08;
    final right = rect.left + rect.width * reach;
    final path = Path()
      ..moveTo(rect.left + jag(), top + 1)
      ..lineTo(right + jag(), top - .5)
      ..lineTo(right + jag(), (top + bottom) / 2)
      ..lineTo(right + jag(), bottom)
      ..lineTo(rect.left + jag(), bottom + .8)
      ..lineTo(rect.left + jag() - 1, (top + bottom) / 2)
      ..close();
    canvas.drawPath(path, Paint()..color = accent.withValues(alpha: alpha));
  }
  frame.paintText(canvas);
}

/// A wave runs through the letters with the voice: each glyph bobs up as the
/// crest passes, leaning into it and warming toward the accent.
void ripple(Canvas canvas, EffectFrame frame) {
  if (frame.finished) {
    frame.paintText(canvas);
    return;
  }
  final rect = frame.wordRect(frame.word);
  final rtl = frame.text.textDirection == TextDirection.rtl;
  final crest = rtl
      ? rect.right - rect.width * frame.wordProgress
      : rect.left + rect.width * frame.wordProgress;
  final glyphs = [
    for (var i = frame.word - 1; i <= frame.word + 1; i++)
      if (i >= 0 && i < frame.words.length) ...frame.glyphs(frame.words[i]),
  ];
  canvas.save();
  canvas.clipPath(frame.outside(glyphs));
  frame.paintText(canvas);
  canvas.restore();
  final ink = frame.colors.onSurface;
  for (final glyph in glyphs) {
    // Only the spoken line moves; neighbors wrapped to other lines stay put.
    final sameLine = (glyph.bottom - rect.bottom).abs() < 1;
    final d = (glyph.center.dx - crest) / (frame.lineHeight * .8);
    final swell = sameLine ? math.exp(-d * d) : 0.0;
    frame.paintGlyph(
      canvas,
      glyph,
      shift: Offset(0, -5 * swell),
      turn: -.18 * d * swell,
      color: Color.lerp(ink, frame.colors.primary, swell)!,
    );
  }
}

/// Sparks lift off each word as it is spoken and drift up into the margin of
/// the line above, while the word itself cools from ember to ink.
void embers(Canvas canvas, EffectFrame frame) {
  frame.paintText(canvas);
  final accent = frame.colors.primary;
  if (!frame.finished) {
    canvas.save();
    canvas.clipRect(frame.wordRect(frame.word).inflate(1));
    frame.paintTextIn(
      canvas,
      Color.lerp(accent, frame.colors.onSurface, frame.wordProgress * .5)!,
    );
    canvas.restore();
  }
  // Ages are in words, so sparks keep pace with the voice at any speed.
  const lifeWords = 4.0;
  for (var i = math.max(0, frame.word - 5); i <= frame.word; i++) {
    final rect = frame.wordRect(i);
    for (var k = 0; k < 6; k++) {
      final r = math.Random(i * 31 + k);
      final age = (frame.wordClock - i - r.nextDouble() * .8) / lifeWords;
      if (age <= 0 || age >= 1) continue;
      final origin = rect.left + r.nextDouble() * rect.width;
      final center = Offset(
        origin + math.sin(age * 7 + k) * 5 * age,
        rect.top + 3 - age * frame.lineHeight * 1.6,
      );
      final fade = math.pow(1 - age, 1.5).toDouble();
      final radius = 1.9 - age * 1.2;
      canvas.drawCircle(
        center,
        radius * 2.6,
        Paint()
          ..color = accent.withValues(alpha: .22 * fade)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()..color = accent.withValues(alpha: .9 * fade),
      );
    }
  }
}
