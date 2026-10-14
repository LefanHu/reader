import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'effect_canvas.dart';

/// The joke hint. One letter of the phrase has come loose and hangs crooked
/// from its corner. A tap and the passage gives up: every letter trembles,
/// hops, tumbles and bounces into a heap at the foot of the paragraph, puffing
/// dust, and the loose letter drops last onto the top of the pile. Tapping
/// again rewinds the collapse.
///
/// Built for speed: the paragraph is rasterized once into an atlas, every
/// trajectory and the heap are solved in closed form ahead of time, and each
/// frame is a single `drawAtlas` call however many letters fall.
void gravity(Canvas canvas, EffectFrame frame) {
  final rubble = _rubble[frame.text] ??= _Rubble(frame);
  final s = frame.activationTime;
  if (s <= 0) {
    _hangLoose(canvas, frame, rubble);
    return;
  }
  final transforms = <RSTransform>[];
  final sources = <Rect>[];
  final dust = Paint()
    ..color = frame.colors.onSurfaceVariant.withValues(alpha: .25);
  for (final body in rubble.bodies) {
    final (center, angle) = body.at(s, frame.time);
    transforms.add(
      RSTransform.fromComponents(
        rotation: angle,
        scale: 1 / rubble.ratio,
        anchorX: body.source.width / 2,
        anchorY: body.source.height / 2,
        translateX: center.dx,
        translateY: center.dy,
      ),
    );
    sources.add(body.source);
    // A brief puff where each letter lands.
    final since = s - body.land;
    if (since > 0 && since < .35) {
      final foot = Offset(
        body.landCenter.dx,
        body.landCenter.dy + body.half.dy,
      );
      final spread = 2 + since * 22;
      final radius = 1.5 + since * 6;
      dust.color = dust.color.withValues(alpha: .25 * (1 - since / .35));
      canvas.drawCircle(foot.translate(-spread, 0), radius, dust);
      canvas.drawCircle(foot.translate(spread, 0), radius, dust);
    }
  }
  canvas.drawAtlas(
    rubble.atlas,
    transforms,
    sources,
    null,
    null,
    null,
    Paint()..filterQuality = FilterQuality.medium,
  );
}

// Keyed by the canvas's laid-out painter, so a relayout or theme change (new
// painter) rebuilds, and the cache dies with the painter.
final _rubble = Expando<_Rubble>('gravity rubble');

/// Resting tilt of the loose letter, in radians; it falls from this pose.
const _lean = .32;

/// Swing of the loose letter: a lazy sway, and every 4s it slips a little
/// further before hauling itself back.
double _swing(double time) {
  final cycle = time % 4;
  final slip = cycle < .25 ? math.sin(cycle / .25 * math.pi) * .35 : 0.0;
  return _lean + .07 * math.sin(time * 2.4) + slip;
}

/// Center of [box] turned by [angle] about its top-left corner.
Offset _hang(Rect box, double angle) {
  final offset = box.center - box.topLeft;
  return box.topLeft +
      Offset(
        offset.dx * math.cos(angle) - offset.dy * math.sin(angle),
        offset.dx * math.sin(angle) + offset.dy * math.cos(angle),
      );
}

/// At rest: the passage is whole except the loose letter, which swings from
/// its top-left corner and slips now and then.
void _hangLoose(Canvas canvas, EffectFrame frame, _Rubble rubble) {
  final loose = rubble.bodies[rubble.loose];
  final box = loose.home;
  canvas.save();
  canvas.clipPath(frame.outside([box]));
  frame.paintText(canvas);
  canvas.restore();
  final angle = _swing(frame.time);
  final swung = _hang(box, angle);
  frame.paintGlyph(canvas, box, shift: swung - box.center, turn: angle);
}

/// Every glyph of the passage as a falling body, with the heap pre-solved.
class _Rubble {
  _Rubble(EffectFrame frame)
    : ratio = math.min(
        3,
        ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 2,
      ) {
    final size = frame.size;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(ratio);
    frame.paintText(canvas);
    final picture = recorder.endRecording();
    atlas = picture.toImageSync(
      (size.width * ratio).ceil(),
      (size.height * ratio).ceil(),
    );
    picture.dispose();

    final glyphs = frame.glyphs(
      TextRange(start: 0, end: frame.text.plainText.length),
    );
    // The anchor's first letter is the one that has come loose.
    loose = math.max(0, glyphs.indexOf(frame.glyphs(frame.anchor).first));
    final random = math.Random(7);
    bodies = [
      for (final (i, box) in glyphs.indexed)
        _Body(
          home: box,
          source: Rect.fromLTRB(
            box.left * ratio,
            box.top * ratio,
            box.right * ratio,
            box.bottom * ratio,
          ),
          // Lower lines give way first; the loose letter waits for its cue.
          release: i == loose
              ? 2.6
              : .45 +
                    random.nextDouble() * .35 +
                    (1 - box.bottom / size.height) * .25,
          velocity: Offset(
            (random.nextDouble() - .5) * 220,
            -random.nextDouble() * (i == loose ? 420 : 160),
          ),
          spin: (random.nextDouble() - .5) * (i == loose ? 18 : 10),
          hanging: i == loose,
        ),
    ];
    _pile(size, frame.lineHeight);
  }

  /// Device pixels per logical pixel in [atlas].
  final double ratio;
  late final ui.Image atlas;
  late final List<_Body> bodies;
  late final int loose;

  static const gravity = 2600.0;

  /// Lands bodies in the order they would reach the floor, each on top of
  /// whatever has already piled up: a heightfield in 3px columns. A letter
  /// that hits the heap slides to the lowest spot within a couple of lines,
  /// like sand, so the pile spreads into a mound instead of a tower.
  void _pile(Size size, double lineHeight) {
    const column = 3.0;
    final heights = List.filled((size.width / column).ceil() + 1, 0.0);
    double heapUnder(double center, double halfWidth) {
      var heap = 0.0;
      final from = ((center - halfWidth) / column).floor();
      final to = ((center + halfWidth) / column).ceil();
      for (var c = from; c <= to; c++) {
        heap = math.max(heap, heights[c.clamp(0, heights.length - 1)]);
      }
      return heap;
    }

    for (final body in bodies) {
      body.solveLanding(size.height - body.half.dy, size.width);
    }
    final reach = lineHeight * 2.5;
    for (final body in [...bodies]..sort((a, b) => a.land.compareTo(b.land))) {
      final hit = body.landCenter.dx;
      var best = hit;
      var bestScore = double.infinity;
      for (var dx = -reach; dx <= reach; dx += column) {
        final x = (hit + dx).clamp(body.half.dx, size.width - body.half.dx);
        // Downhill wins, but a short slide beats a long one at equal height.
        final score = heapUnder(x, body.half.dx) + dx.abs() * .15;
        if (score < bestScore) {
          bestScore = score;
          best = x;
        }
      }
      final heap = heapUnder(best, body.half.dx);
      body.solveLanding(size.height - heap - body.half.dy, size.width);
      body.restX = best;
      // Letters nest a little into each other, so the mound slumps.
      final from = ((best - body.half.dx) / column).floor();
      final to = ((best + body.half.dx) / column).ceil();
      for (var c = from; c <= to; c++) {
        heights[c.clamp(0, heights.length - 1)] = heap + body.half.dy * 1.2;
      }
    }
  }
}

class _Body {
  _Body({
    required this.home,
    required this.source,
    required this.release,
    required this.velocity,
    required this.spin,
    required this.hanging,
  }) : _start = hanging ? _hang(home, _lean) : home.center,
       _startAngle = hanging ? _lean : 0;

  /// Laid-out box and atlas source, in logical and device pixels.
  final Rect home, source;

  /// Seconds into the response when the letter lets go.
  final double release;

  /// Launch velocity in px/s and spin in rad/s.
  final Offset velocity;
  final double spin;

  /// The loose letter keeps swinging until it lets go, then falls from its
  /// crooked pose rather than snapping back into line.
  final bool hanging;

  /// Center and angle the fall starts from.
  final Offset _start;
  final double _startAngle;

  late double land;
  late Offset landCenter;

  /// Where the letter comes to rest after sliding down the heap.
  late double restX;
  Offset get half => Offset(home.width / 2, home.height / 2);

  /// Solves the fall for a resting center height of [restY].
  void solveLanding(double restY, double width) {
    final drop = math.max(0.0, restY - _start.dy);
    final vy = velocity.dy;
    final flight =
        (-vy + math.sqrt(vy * vy + 2 * _Rubble.gravity * drop)) /
        _Rubble.gravity;
    land = release + flight;
    landCenter = Offset(
      (_start.dx + velocity.dx * flight).clamp(half.dx, width - half.dx),
      restY,
    );
  }

  /// Center and angle [s] seconds into the response.
  (Offset, double) at(double s, double time) {
    if (s < release) {
      if (hanging) {
        final angle = _swing(time);
        return (_hang(home, angle), angle);
      }
      // Anticipation: tremble harder the closer the letter is to letting go.
      final ramp = math.min(1.0, s / .45);
      final seed = home.left * .37 + home.top;
      return (
        home.center + Offset(math.sin(time * 53 + seed) * 1.2 * ramp, 0),
        math.sin(time * 41 + seed) * .07 * ramp,
      );
    }
    if (s < land) {
      final t = s - release;
      final x = _start.dx + velocity.dx * t;
      final y = _start.dy + velocity.dy * t + .5 * _Rubble.gravity * t * t;
      return (Offset(x, y), _startAngle + spin * t);
    }
    // Damped bounces while sliding downhill, settling at a crooked angle.
    final t = s - land;
    final settle = 1 - math.exp(-6 * t);
    final impact = math.min(home.height * .8, (land - release) * 90);
    final bounce = impact * math.exp(-5 * t) * math.sin(16 * t).abs();
    return (
      Offset(
        landCenter.dx + (restX - landCenter.dx) * settle,
        landCenter.dy - bounce,
      ),
      _startAngle + spin * (land - release) + spin * .08 * settle,
    );
  }
}
