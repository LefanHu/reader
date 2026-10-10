import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Collects indexed triangles so each side of the sheet needs one canvas draw.
class CurlMesh {
  /// Owned mesh data accumulated for this side of the sheet.
  final positions = <Offset>[];

  /// Owned mesh data accumulated for this side of the sheet.
  final textures = <Offset>[];

  /// Owned mesh data accumulated for this side of the sheet.
  final colors = <Color>[];

  /// Owned mesh data accumulated for this side of the sheet.
  final indices = <int>[];

  /// Appends a triangulated polygon with matching texture and shading data.
  void polygon(List<Offset> points, List<Offset> uv, List<Color> shading) {
    /// Owned mesh data accumulated for this side of the sheet.
    final base = positions.length;
    positions.addAll(points);
    textures.addAll(uv);
    colors.addAll(shading);
    for (var i = 1; i + 1 < points.length; i++) {
      indices
        ..add(base)
        ..add(base + i)
        ..add(base + i + 1);
    }
  }

  /// Draws and releases temporary vertices while retaining mesh data.
  void draw(Canvas canvas, Paint paint, BlendMode blend) {
    if (positions.isEmpty) return;

    /// Owned mesh data accumulated for this side of the sheet.
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
