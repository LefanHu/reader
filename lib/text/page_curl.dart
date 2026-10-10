import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'curl_mesh.dart';

/// Paints two already-shaped page textures without changing text or positions.
///
/// The caller owns both images. A cylindrical fold is tessellated into front
/// and reverse meshes; texture coordinates always refer to the original page.
/// Reverse turns unfold the incoming sheet, rather than distorting live text.
class PaperCurlPainter extends CustomPainter {
  /// Creates a visual-only preview. [progress] is clamped to the unit interval.
  PaperCurlPainter({
    required this.current,
    required this.target,
    required this.progress,
    required this.grabY,
    required this.fingerY,
    required this.forward,
    required this.fromRight,
    required this.paper,
  });

  /// Texture of the last committed page; never the accessibility source.
  final ui.Image current;

  /// Texture of the adjacent page, excluded from reading-position reporting.
  final ui.Image target;

  /// Fraction of the turn, where one is a completed navigation.
  final double progress;

  /// Initial page-local grab height in logical pixels. [progress] carries
  /// horizontal movement; these heights control the two-dimensional bend.
  final double grabY;

  /// Live page-local pointer height, frozen while the released turn settles.
  final double fingerY;

  /// Whether the outgoing sheet curls away or the incoming sheet unfolds.
  final bool forward;

  /// Forward sheet's fold edge, mirrored for RTL. Reverse turns unfold the
  /// same geometry so incoming paper travels with the backward gesture.
  final bool fromRight;

  /// Theme surface used for paper, its reverse, and the exposed background.
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final p = progress.clamp(0.0, 1.0);
    final rect = Offset.zero & size;
    void image(ui.Image image) => canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      rect,
      Paint()..filterQuality = FilterQuality.medium,
    );
    if (p == 0 || p == 1) {
      image(p == 0 ? current : target);
      return;
    }
    image(forward ? target : current);
    final sheet = forward ? current : target;
    final curl = forward ? p : 1 - p;
    final taper = math.sin(math.pi * curl);
    final grab = grabY.clamp(0.0, size.height);
    final finger = fingerY.clamp(-size.height, 2 * size.height);
    final anchorX = size.width * (1 - curl);
    final anchorY = finger;
    final slope =
        (.6 * (.5 - grab / size.height) + (finger - grab) / size.width).clamp(
          -.8,
          .8,
        ) *
        taper;
    final inverseLength = 1 / math.sqrt(1 + slope * slope);
    final normalX = inverseLength;
    final normalY = -slope * inverseLength;
    final tangentX = slope * inverseLength;
    final tangentY = inverseLength;
    final radius = math.max(.000001, size.width * .095 * taper);
    final front = CurlMesh();
    final reverse = CurlMesh();

    // Projection, side classification and shadow share one page-local crease.
    // Scalar frame geometry avoids allocating normal/anchor objects per vertex.
    double distance(double x, double y) =>
        (x - anchorX) * normalX + (y - anchorY) * normalY;
    double mirrorX(double x) => fromRight ? x : size.width - x;
    Offset project(double x, double y) {
      final d = distance(x, y);
      final displacement = d <= 0
          ? 0.0
          : d <= math.pi * radius
          ? radius * math.sin(d / radius) - d
          : math.pi * radius - 2 * d;
      return Offset(
        mirrorX(x + normalX * displacement),
        y + normalY * displacement,
      );
    }

    final boundaries = [0.0, math.pi * radius / 2, math.pi * radius];
    void emit(List<Offset> source) {
      var centerDistance = 0.0;
      for (final v in source) {
        centerDistance += distance(v.dx, v.dy);
      }
      final back = centerDistance / source.length > boundaries[1];
      final mesh = back ? reverse : front;
      mesh.polygon(
        source.map((v) => project(v.dx, v.dy)).toList(),
        source
            .map(
              (v) => Offset(
                mirrorX(v.dx) / size.width * sheet.width,
                v.dy / size.height * sheet.height,
              ),
            )
            .toList(),
        source.map((v) {
          // Vertex lighting avoids row-sized shade steps on diagonal folds.
          final angle = (distance(v.dx, v.dy) / radius).clamp(0.0, math.pi);
          final light = 1 - .18 * math.sin(angle);
          return back
              ? Color.lerp(paper, Colors.black, (1 - light) * .6)!
              : Color.fromRGBO(
                  (255 * light).round(),
                  (255 * light).round(),
                  (255 * light).round(),
                  1,
                );
        }).toList(),
      );
    }

    // Only crease-straddling triangles need extra vertices. Each intersection
    // is shared by both pieces; UVs come from the same interpolated source point.
    void splitTriangle(List<Offset> triangle) {
      var pieces = [triangle];
      for (final boundary in boundaries) {
        final next = <List<Offset>>[];
        for (final piece in pieces) {
          var hasLow = false;
          var hasHigh = false;
          for (final vertex in piece) {
            final d = distance(vertex.dx, vertex.dy);
            hasLow |= d < boundary;
            hasHigh |= d > boundary;
            if (hasLow && hasHigh) break;
          }
          if (!hasLow || !hasHigh) {
            next.add(piece);
            continue;
          }
          final low = <Offset>[];
          final high = <Offset>[];
          var previous = piece.last;
          var previousD = distance(previous.dx, previous.dy);
          for (final vertex in piece) {
            final d = distance(vertex.dx, vertex.dy);
            if ((previousD < boundary && d > boundary) ||
                (previousD > boundary && d < boundary)) {
              final fraction = (boundary - previousD) / (d - previousD);
              final intersection = Offset(
                previous.dx + (vertex.dx - previous.dx) * fraction,
                previous.dy + (vertex.dy - previous.dy) * fraction,
              );
              low.add(intersection);
              high.add(intersection);
            }
            if (d <= boundary) low.add(vertex);
            if (d >= boundary) high.add(vertex);
            previous = vertex;
            previousD = d;
          }
          if (low.length >= 3) next.add(low);
          if (high.length >= 3) next.add(high);
        }
        pieces = next;
      }
      for (final piece in pieces) {
        emit(piece);
      }
    }

    const columns = 100;
    const rows = 12;
    for (var col = 0; col < columns; col++) {
      final x0 = size.width * col / columns;
      final x1 = size.width * (col + 1) / columns;
      for (var row = 0; row < rows; row++) {
        final y0 = size.height * row / rows;
        final y1 = size.height * (row + 1) / rows;
        final corners = [
          Offset(x0, y0),
          Offset(x1, y0),
          Offset(x1, y1),
          Offset(x0, y1),
        ];
        var minimum = double.infinity;
        var maximum = double.negativeInfinity;
        for (final vertex in corners) {
          final d = distance(vertex.dx, vertex.dy);
          minimum = math.min(minimum, d);
          maximum = math.max(maximum, d);
        }
        if (boundaries.any(
          (boundary) => minimum < boundary && maximum > boundary,
        )) {
          splitTriangle([corners[0], corners[1], corners[2]]);
          splitTriangle([corners[0], corners[2], corners[3]]);
        } else {
          emit(corners);
        }
      }
    }
    canvas.save();
    canvas.clipRect(rect);
    final shadowX = anchorX + normalX * radius;
    final shadowY = anchorY + normalY * radius;
    final shadowWidth = radius * 1.5;
    final extent =
        2 * math.sqrt(size.width * size.width + size.height * size.height);
    Offset shadowPoint(double normal, double tangent) => Offset(
      mirrorX(shadowX + normalX * normal + tangentX * tangent),
      shadowY + normalY * normal + tangentY * tangent,
    );
    final start = shadowPoint(-shadowWidth, 0);
    final end = shadowPoint(shadowWidth, 0);
    final ribbon = Path()
      ..addPolygon([
        shadowPoint(-shadowWidth, -extent),
        shadowPoint(shadowWidth, -extent),
        shadowPoint(shadowWidth, extent),
        shadowPoint(-shadowWidth, extent),
      ], true);
    canvas.drawPath(
      ribbon,
      Paint()
        ..shader = ui.Gradient.linear(
          start,
          end,
          [
            Colors.transparent,
            Colors.black.withValues(alpha: .22),
            Colors.transparent,
          ],
          [0, .5, 1],
        ),
    );
    final shader = ui.ImageShader(
      sheet,
      TileMode.clamp,
      TileMode.clamp,
      Float64List.fromList([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]),
    );
    front.draw(canvas, Paint()..shader = shader, BlendMode.modulate);
    reverse.draw(canvas, Paint(), BlendMode.dst);
    // The reverse is opaque paper with a trace of mirrored printing.
    reverse.draw(
      canvas,
      Paint()
        ..shader = shader
        ..color = Colors.white.withValues(alpha: .10),
      BlendMode.src,
    );
    canvas.restore();
    shader.dispose();
  }

  @override
  bool shouldRepaint(PaperCurlPainter oldDelegate) =>
      oldDelegate.current != current ||
      oldDelegate.target != target ||
      oldDelegate.progress != progress ||
      oldDelegate.grabY != grabY ||
      oldDelegate.fingerY != fingerY ||
      oldDelegate.forward != forward ||
      oldDelegate.fromRight != fromRight ||
      oldDelegate.paper != paper;
}
