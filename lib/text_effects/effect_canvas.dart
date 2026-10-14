import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Paints one animation frame, including the passage text itself, so an effect
/// can recolor, clip or displace glyphs as well as draw around them.
typedef TextEffect = void Function(Canvas canvas, EffectFrame frame);

/// Everything an effect may read for one frame. Geometry comes from the same
/// [TextPainter] queries the reader's slice painter uses, so a chosen effect
/// can move into `TextSlicePainter` without new layout code.
class EffectFrame {
  /// Snapshot built inside `paint`, never cached across frames.
  const EffectFrame({
    required this.text,
    required this.size,
    required this.anchor,
    required this.words,
    required this.time,
    required this.wordClock,
    required this.activation,
    required this.activationTime,
    required this.colors,
  });

  /// Laid-out passage owned by the canvas.
  final TextPainter text;

  /// Painted extent: passage width by laid-out height.
  final Size size;

  /// Illustrated phrase within the passage.
  final TextRange anchor;

  /// Whitespace-delimited words in reading order.
  final List<TextRange> words;

  /// Seconds the canvas has been playing; fixed when motion is reduced.
  final double time;

  /// Fractional index of the word being spoken: 4.25 is a quarter into the
  /// fifth word. Values past the last word mean the sentence has finished.
  final double wordClock;

  /// 0 at rest, 1 once a tap has asked for the illustration.
  final double activation;

  /// Seconds into the tap response along the forward timeline, uneased, for
  /// effects that simulate motion. Reversing rewinds it at reverse speed.
  final double activationTime;

  /// Active theme; ink is `onSurface`, accent is `primary`.
  final ColorScheme colors;

  /// Whether the clock has passed the last word.
  bool get finished => wordClock >= words.length;

  /// Index of the word being spoken, clamped to the passage.
  int get word => math.min(wordClock.floor(), words.length - 1);

  /// Progress through the current word, 1 once the sentence has finished.
  double get wordProgress => finished ? 1 : wordClock - wordClock.floor();

  /// Body line height, independent of glyph run bounds.
  double get lineHeight => text.preferredLineHeight;

  /// Tight run boxes for a source range, one or more per line.
  List<Rect> boxes(TextRange range) => [
    for (final box in text.getBoxesForSelection(
      TextSelection(baseOffset: range.start, extentOffset: range.end),
    ))
      box.toRect(),
  ];

  /// Bounds of one word; words never break across lines.
  Rect wordRect(int index) =>
      boxes(words[index.clamp(0, words.length - 1)])
          .reduce((a, b) => a.expandToInclude(b));

  /// Paints the passage in its laid-out ink.
  void paintText(Canvas canvas) => text.paint(canvas, Offset.zero);

  /// Paints the passage recolored to [color], keeping glyph antialiasing.
  void paintTextIn(Canvas canvas, Color color) {
    canvas.saveLayer(
      Offset.zero & size,
      Paint()..colorFilter = ColorFilter.mode(color, BlendMode.srcIn),
    );
    paintText(canvas);
    canvas.restore();
  }

  /// Box of every visible grapheme in [range], in reading order. Spaces are
  /// skipped so per-letter effects never animate empty boxes.
  List<Rect> glyphs(TextRange range) {
    final result = <Rect>[];
    var offset = range.start;
    for (final grapheme in range.textInside(text.plainText).characters) {
      final end = offset + grapheme.length;
      if (grapheme.trim().isNotEmpty) {
        final found = boxes(TextRange(start: offset, end: end));
        if (found.isNotEmpty) result.add(found.first);
      }
      offset = end;
    }
    return result;
  }

  /// Paints only the glyph in [box], displaced by [shift], turned by [turn]
  /// radians and scaled about its center. Callers clip the glyph out of the
  /// base text first so it is never painted twice.
  void paintGlyph(
    Canvas canvas,
    Rect box, {
    Offset shift = Offset.zero,
    double turn = 0,
    double scale = 1,
    Color? color,
  }) {
    final center = box.center;
    canvas.save();
    canvas.translate(center.dx + shift.dx, center.dy + shift.dy);
    canvas.rotate(turn);
    canvas.scale(scale);
    canvas.translate(-center.dx, -center.dy);
    // Tight run boxes can shave side bearings; a pixel of slack keeps serifs.
    canvas.clipRect(box.inflate(1));
    if (color == null) {
      paintText(canvas);
    } else {
      paintTextIn(canvas, color);
    }
    canvas.restore();
  }

  /// Union of [rects] as a fill path for clipping.
  static Path pathOf(Iterable<Rect> rects) {
    final path = Path();
    for (final rect in rects) {
      path.addRect(rect);
    }
    return path;
  }

  /// Everything outside [rects], for painting text around a decorated range.
  Path outside(Iterable<Rect> rects) => Path.combine(
    PathOperation.difference,
    Path()..addRect((Offset.zero & size).inflate(lineHeight)),
    pathOf(rects),
  );
}

/// Paints [text] through one effect on a looping clock. Gallery tiles and the
/// detail view share it so an effect looks the same at both sizes.
class EffectCanvas extends StatefulWidget {
  /// [anchor] must occur in [text]; narration effects ignore it.
  const EffectCanvas({
    super.key,
    required this.text,
    required this.anchor,
    required this.effect,
    required this.style,
    this.narration = false,
    this.interactive = false,
    this.playing = true,
    this.activationDuration = const Duration(milliseconds: 700),
  });

  /// Passage laid out with [style].
  final String text;

  /// Illustrated phrase within [text].
  final String anchor;

  /// Frame painter.
  final TextEffect effect;

  /// Reader body style, so the preview matches the user's typography.
  final TextStyle style;

  /// Narration effects advance a word clock; others wait for a tap.
  final bool narration;

  /// Whether a tap toggles the illustration response.
  final bool interactive;

  /// Pausing freezes the clock where it is; resuming continues from there.
  final bool playing;

  /// Length of the tap response; reversing always takes 600ms.
  final Duration activationDuration;

  @override
  State<EffectCanvas> createState() => _EffectCanvasState();
}

class _EffectCanvasState extends State<EffectCanvas>
    with TickerProviderStateMixin {
  // An hour-long repeating clock gives effects a continuous time in seconds.
  late final _clock = AnimationController(
    vsync: this,
    duration: const Duration(hours: 1),
  );
  late final _activation = AnimationController(
    vsync: this,
    duration: widget.activationDuration,
    reverseDuration: const Duration(milliseconds: 600),
  );
  late final List<TextRange> _words = [
    for (final match in RegExp(r'\S+').allMatches(widget.text))
      TextRange(start: match.start, end: match.end),
  ];
  late final TextRange _anchor = () {
    final start = widget.text.indexOf(widget.anchor);
    return TextRange(start: start, end: start + widget.anchor.length);
  }();
  TextPainter? _text;
  Object? _textKey;
  bool _reduceMotion = false;
  bool _active = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) _activation.value = _active ? 1 : 0;
    _syncClock();
  }

  @override
  void didUpdateWidget(EffectCanvas old) {
    super.didUpdateWidget(old);
    _syncClock();
  }

  void _syncClock() {
    if (_reduceMotion || !widget.playing) {
      _clock.stop();
    } else if (!_clock.isAnimating) {
      _clock.repeat();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    _activation.dispose();
    _text?.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _active = !_active);
    if (_reduceMotion) {
      _activation.value = _active ? 1 : 0;
    } else if (_active) {
      _activation.forward();
    } else {
      _activation.reverse();
    }
  }

  TextPainter _layout(double width) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final key = (width, widget.style, scaler, direction);
    if (key != _textKey) {
      _text?.dispose();
      _text = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        textDirection: direction,
        textScaler: scaler,
      )..layout(maxWidth: width);
      _textKey = key;
    }
    return _text!;
  }

  @override
  Widget build(BuildContext context) {
    final canvas = LayoutBuilder(
      builder: (context, constraints) {
        final text = _layout(constraints.maxWidth);
        return CustomPaint(
          size: Size(constraints.maxWidth, text.height),
          painter: _EffectPainter(
            text: text,
            effect: widget.effect,
            clock: _clock,
            activation: _activation,
            colors: Theme.of(context).colorScheme,
            anchor: _anchor,
            words: _words,
            narration: widget.narration,
            animate: !_reduceMotion,
          ),
        );
      },
    );
    return Semantics(
      container: true,
      label: widget.text,
      button: widget.interactive,
      selected: widget.interactive ? _active : null,
      onTap: widget.interactive ? _toggle : null,
      excludeSemantics: true,
      child: widget.interactive
          ? InkWell(
              onTap: _toggle,
              splashFactory: NoSplash.splashFactory,
              highlightColor: Colors.transparent,
              hoverColor: Colors.transparent,
              child: canvas,
            )
          : canvas,
    );
  }
}

class _EffectPainter extends CustomPainter {
  _EffectPainter({
    required this.text,
    required this.effect,
    required this.clock,
    required this.activation,
    required this.colors,
    required this.anchor,
    required this.words,
    required this.narration,
    required this.animate,
  }) : super(repaint: Listenable.merge([clock, activation]));

  final TextPainter text;
  final TextEffect effect;
  final Animation<double> clock;
  final AnimationController activation;
  final ColorScheme colors;
  final TextRange anchor;
  final List<TextRange> words;
  final bool narration, animate;

  /// Narration reads about three words a second, then rests for four beats.
  static const _wordsPerSecond = 3.0;
  static const _restWords = 4;

  @override
  void paint(Canvas canvas, Size size) {
    // Reduced motion freezes a representative frame: a hint at rest, or
    // narration a little under halfway through the passage.
    final time = animate
        ? clock.value * const Duration(hours: 1).inSeconds
        : 1.2;
    var wordClock = 0.0;
    if (narration && animate) {
      wordClock = time * _wordsPerSecond % (words.length + _restWords);
    } else if (narration) {
      wordClock = words.length * .45 + .5;
    }
    effect(
      canvas,
      EffectFrame(
        text: text,
        size: size,
        anchor: anchor,
        words: words,
        time: time,
        wordClock: wordClock,
        activation: Curves.easeInOut.transform(activation.value),
        activationTime:
            activation.value * activation.duration!.inMicroseconds / 1e6,
        colors: colors,
      ),
    );
  }

  @override
  bool shouldRepaint(_EffectPainter old) =>
      old.text != text ||
      old.effect != effect ||
      old.colors != colors ||
      old.narration != narration ||
      old.animate != animate;
}
