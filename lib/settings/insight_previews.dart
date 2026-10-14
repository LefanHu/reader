import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Which ghost chart a preview draws.
enum _Chart { calendar, bars, line }

/// Placeholder charts for account history Reader does not record yet.
///
/// Each chart draws fixed sample shapes inside a dashed frame, so it reads as a
/// preview rather than data. Nothing here touches the network or storage.
class InsightPreviews extends StatelessWidget {
  /// Lays out the reading calendar full width and pairs the two smaller charts.
  const InsightPreviews({super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 20.0;
      final paired = constraints.maxWidth >= 480;
      final width = paired
          ? (constraints.maxWidth - gap) / 2
          : constraints.maxWidth;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Preview(
            chart: _Chart.calendar,
            height: 112,
            title: 'Reading days',
            description: 'Which days you read and for how long. Reading sessions are not recorded yet.',
          ),
          const SizedBox(height: gap),
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              SizedBox(
                width: width,
                child: const _Preview(
                  chart: _Chart.bars,
                  height: 96,
                  title: 'Monthly cost',
                  description: 'What narration and illustrations cost each month. Billing history is not kept yet.',
                ),
              ),
              SizedBox(
                width: width,
                child: const _Preview(
                  chart: _Chart.line,
                  height: 96,
                  title: 'Model tokens',
                  description: 'Tokens used to analyze, narrate and illustrate your books, by day. Token use is not tracked yet.',
                ),
              ),
            ],
          ),
        ],
      );
    },
  );
}

class _Preview extends StatelessWidget {
  const _Preview({
    required this.chart,
    required this.height,
    required this.title,
    required this.description,
  });

  final _Chart chart;
  final double height;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(
          child: SizedBox(
            height: height,
            child: CustomPaint(
              painter: _GhostChartPainter(
                chart: chart,
                ink: scheme.onSurfaceVariant,
                frame: scheme.outlineVariant,
                mirrored: Directionality.of(context) == TextDirection.rtl,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          title,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          description,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Fixed sample shapes so previews look identical on every frame.
const _barHeights = [.38, .52, .44, .71, .6, .84];
const _linePoints = [.3, .42, .36, .55, .48, .62, .5, .7, .58, .76, .66, .8];

/// Paints a dashed frame and a muted sample chart; time runs toward the end edge.
class _GhostChartPainter extends CustomPainter {
  _GhostChartPainter({
    required this.chart,
    required this.ink,
    required this.frame,
    required this.mirrored,
  });

  final _Chart chart;
  final Color ink;
  final Color frame;
  final bool mirrored;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = frame
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final border = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(.5),
          const Radius.circular(10),
        ),
      );
    for (final metric in border.computeMetrics()) {
      for (var at = 0.0; at < metric.length; at += 9) {
        canvas.drawPath(
          metric.extractPath(at, math.min(at + 5, metric.length)),
          stroke,
        );
      }
    }
    if (mirrored) {
      canvas
        ..translate(size.width, 0)
        ..scale(-1, 1);
    }
    final area = (Offset.zero & size).deflate(16);
    switch (chart) {
      case _Chart.calendar:
        _calendar(canvas, area);
      case _Chart.bars:
        _bars(canvas, area);
      case _Chart.line:
        _line(canvas, area);
    }
  }

  void _calendar(Canvas canvas, Rect area) {
    const rows = 7, gap = 3.0;
    final cell = (area.height - gap * (rows - 1)) / rows;
    final columns = ((area.width + gap) / (cell + gap)).floor();
    final paint = Paint();
    for (var column = 0; column < columns; column++) {
      for (var row = 0; row < rows; row++) {
        // Multiplicative hash of the day index: scattered, but stable.
        final bucket = ((column * rows + row) * 2654435761 % 4294967296) >> 29;
        final level = math.max(0, bucket - 3);
        paint.color = level == 0
            ? frame.withValues(alpha: .5)
            : ink.withValues(alpha: .1 + level * .1);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              area.left + column * (cell + gap),
              area.top + row * (cell + gap),
              cell,
              cell,
            ),
            const Radius.circular(2),
          ),
          paint,
        );
      }
    }
  }

  void _bars(Canvas canvas, Rect area) {
    final slot = area.width / _barHeights.length;
    final paint = Paint()..color = ink.withValues(alpha: .22);
    for (var i = 0; i < _barHeights.length; i++) {
      final height = area.height * _barHeights[i];
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(
            area.left + i * slot + slot * .2,
            area.bottom - height,
            slot * .6,
            height,
          ),
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
        paint,
      );
    }
    canvas.drawLine(area.bottomLeft, area.bottomRight, Paint()..color = frame);
  }

  void _line(Canvas canvas, Rect area) {
    Offset point(int i) => Offset(
      area.left + area.width * i / (_linePoints.length - 1),
      area.bottom - area.height * _linePoints[i],
    );
    final line = Path()..moveTo(point(0).dx, point(0).dy);
    for (var i = 1; i < _linePoints.length; i++) {
      line.lineTo(point(i).dx, point(i).dy);
    }
    final fill = Path.from(line)
      ..lineTo(area.right, area.bottom)
      ..lineTo(area.left, area.bottom)
      ..close();
    canvas
      ..drawPath(fill, Paint()..color = ink.withValues(alpha: .08))
      ..drawPath(
        line,
        Paint()
          ..color = ink.withValues(alpha: .4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeJoin = StrokeJoin.round,
      );
  }

  @override
  bool shouldRepaint(_GhostChartPainter old) =>
      old.chart != chart ||
      old.ink != ink ||
      old.frame != frame ||
      old.mirrored != mirrored;
}
