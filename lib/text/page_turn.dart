import 'dart:ui' as ui;

import 'page_target.dart';

/// Owns exactly two textures, or none when reduced motion is enabled.
class PageTurn {
  /// Transfers the current and incoming textures into this turn.
  PageTurn(this.target, this.current, this.incoming, this.delta);

  /// Borrowed destination committed only when the turn completes.
  final PageTarget target;

  /// Owned page textures, both absent for reduced motion.
  final ui.Image? current, incoming;

  /// Logical reading direction, independent of visual paragraph direction.
  final int delta;

  /// Releases the resources owned by this component.
  void dispose() {
    current?.dispose();
    incoming?.dispose();
  }
}
