import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

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

  /// Whether the outgoing sheet curls away or the incoming sheet unfolds.
  final bool forward;

  /// Forward sheet's fold edge, mirrored for RTL. Reverse turns unfold the
  /// same geometry so incoming paper travels with the backward gesture.
  final bool fromRight;

  /// Theme surface used for paper, its reverse, and the exposed background.
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
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
    final fold = size.width * (1 - 1.1 * curl);
    final radius = size.width * (.015 + .08 * math.sin(math.pi * curl));
    final front = _Mesh();
    final reverse = _Mesh();

    // A slight diagonal bend gives the fold depth without introducing seams
    // between independently transformed strips. The complete mesh shares UVs.
    Offset project(double x, double y) {
      final localFold =
          fold +
          .06 * size.width * math.sin(math.pi * curl) * (y / size.height - .5);
      final distance = x - localFold;
      var mapped = x;
      var lift = 0.0;
      if (distance > 0) {
        final angle = math.min(math.pi, distance / radius);
        mapped = distance <= math.pi * radius
            ? localFold + radius * math.sin(angle)
            : localFold - (distance - math.pi * radius);
        lift = radius * (1 - math.cos(angle));
      }
      return Offset(
        fromRight ? mapped : size.width - mapped,
        y + lift * .12 * (y / size.height - .5),
      );
    }

    const columns = 100;
    const rows = 12;
    for (var col = 0; col < columns; col++) {
      final x0 = size.width * col / columns;
      final x1 = size.width * (col + 1) / columns;
      for (var row = 0; row < rows; row++) {
        final y0 = size.height * row / rows;
        final y1 = size.height * (row + 1) / rows;
        final angle = ((x0 + x1) / 2 - fold) / radius;
        final back = angle > math.pi / 2;
        final light = 1 - .18 * math.sin(angle.clamp(0, math.pi));
        final color = back
            ? Color.lerp(paper, Colors.black, (1 - light) * .6)!
            : Color.fromRGBO(
                (255 * light).round(),
                (255 * light).round(),
                (255 * light).round(),
                1,
              );
        final mesh = back ? reverse : front;
        final corners = [
          Offset(x0, y0),
          Offset(x1, y0),
          Offset(x1, y1),
          Offset(x0, y1),
        ];
        mesh.quad(
          corners.map((v) => project(v.dx, v.dy)).toList(),
          corners
              .map(
                (v) => Offset(
                  (fromRight ? v.dx : size.width - v.dx) /
                      size.width *
                      sheet.width,
                  v.dy / size.height * sheet.height,
                ),
              )
              .toList(),
          color,
        );
      }
    }
    canvas.save();
    canvas.clipRect(rect);
    final edge = fromRight ? fold + radius : size.width - fold - radius;
    final shadowWidth = radius * 1.5;
    final shadow = Rect.fromLTWH(
      edge - shadowWidth,
      0,
      shadowWidth * 2,
      size.height,
    );
    canvas.drawRect(
      shadow,
      Paint()
        ..shader = ui.Gradient.linear(
          shadow.centerLeft,
          shadow.centerRight,
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
      oldDelegate.forward != forward ||
      oldDelegate.fromRight != fromRight ||
      oldDelegate.paper != paper;
}

/// Collects indexed triangles so each side of the sheet needs one canvas draw.
class _Mesh {
  final positions = <Offset>[];
  final textures = <Offset>[];
  final colors = <Color>[];
  final indices = <int>[];

  void quad(List<Offset> points, List<Offset> uv, Color color) {
    final base = positions.length;
    positions.addAll(points);
    textures.addAll(uv);
    colors.addAll(List.filled(4, color));
    indices.addAll([base, base + 1, base + 2, base, base + 2, base + 3]);
  }

  void draw(Canvas canvas, Paint paint, BlendMode blend) {
    if (positions.isEmpty) return;
    final vertices = ui.Vertices(
      ui.VertexMode.triangles,
      positions,
      textureCoordinates: textures,
      colors: colors,
      indices: indices,
    );
    canvas.drawVertices(vertices, blend, paint);
    vertices.dispose();
  }
}
