import 'package:flutter/painting.dart';

import '../text_section.dart' as text;
import 'section_layout.dart';

/// Retains at most two measured section layouts and owns their painters.
class SectionLayoutCache {
  final _layouts = <Object, SectionLayout>{};

  /// Number of retained layouts.
  int get length => _layouts.length;

  /// Identity of a layout for one section, viewport, typography and scale.
  Object keyFor({
    required text.TextSection section,
    required double width,
    required double height,
    required TextStyle style,
    required TextScaler scaler,
  }) => (section.id, width, height, style, scaler.scale(20));

  /// Returns the cached or newly measured layout, evicting older ones.
  ///
  /// The [committed] layout remains alive while an adjacent section is
  /// previewed; victims are disposed.
  SectionLayout obtain({
    required text.TextSection section,
    required double width,
    required double height,
    required TextStyle style,
    required TextScaler scaler,
    required SectionLayout? committed,
  }) {
    final key = keyFor(
      section: section,
      width: width,
      height: height,
      style: style,
      scaler: scaler,
    );
    final layout =
        _layouts.remove(key) ??
        SectionLayout(section, width, height, style, scaler);
    _layouts[key] = layout;
    while (_layouts.length > 2) {
      final victim = _layouts.keys.firstWhere(
        (key) => _layouts[key] != committed && _layouts[key] != layout,
        orElse: () => _layouts.keys.first,
      );
      _layouts.remove(victim)!.dispose();
    }
    return layout;
  }

  /// Releases every retained layout.
  void dispose() {
    for (final layout in _layouts.values) {
      layout.dispose();
    }
    _layouts.clear();
  }
}
