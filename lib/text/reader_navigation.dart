import 'package:flutter/foundation.dart';

import 'text_position.dart';

/// Commands address logical reading order rather than visual RTL direction.
class TextReaderNavigation {
  /// Owned by the reader shell and attached only while a viewport is mounted.
  TextReaderNavigation();

  Object? _owner;
  TextPosition? Function()? _leadingPosition;
  bool Function()? _rightToLeft;
  int Function()? _retainedLayoutCount;
  int Function()? _retainedTextureCount;
  VoidCallback? _next, _previous, _nextSection, _previousSection;
  void Function(TextPosition)? _goTo;
  Future<void> Function(TextPosition)? _restore;

  /// Binds live viewport callbacks once during lifecycle attachment.
  void attach(
    Object owner, {
    required TextPosition? Function() leadingPosition,
    required bool Function() rightToLeft,
    required int Function() retainedLayoutCount,
    required int Function() retainedTextureCount,
    required VoidCallback next,
    required VoidCallback previous,
    required VoidCallback nextSection,
    required VoidCallback previousSection,
    required void Function(TextPosition) goTo,
    required Future<void> Function(TextPosition) restore,
  }) {
    _owner = owner;
    _leadingPosition = leadingPosition;
    _rightToLeft = rightToLeft;
    _retainedLayoutCount = retainedLayoutCount;
    _retainedTextureCount = retainedTextureCount;
    _next = next;
    _previous = previous;
    _nextSection = nextSection;
    _previousSection = previousSection;
    _goTo = goTo;
    _restore = restore;
  }

  /// Clears callbacks only when the currently attached owner is identical.
  void detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _leadingPosition = null;
    _rightToLeft = null;
    _retainedLayoutCount = null;
    _retainedTextureCount = null;
    _next = null;
    _previous = null;
    _nextSection = null;
    _previousSection = null;
    _goTo = null;
    _restore = null;
  }

  /// Current logical anchor, retained through typography and viewport changes.
  TextPosition? get leadingPosition => _leadingPosition?.call();

  /// Spatial controls follow the current section's paragraph direction.
  bool get rightToLeft => _rightToLeft?.call() ?? false;

  /// Bounded engine layout count, exposed for memory regression tests.
  @visibleForTesting
  int get retainedLayoutCount => _retainedLayoutCount?.call() ?? 0;

  /// Number of turn textures owned by the viewport, for memory regressions.
  @visibleForTesting
  int get retainedTextureCount => _retainedTextureCount?.call() ?? 0;

  /// Advances one page or viewport in logical reading order.
  void next() => _next?.call();

  /// Returns one page or viewport in logical reading order.
  void previous() => _previous?.call();

  /// Opens the next normalized section.
  void nextSection() => _nextSection?.call();

  /// Opens the previous normalized section.
  void previousSection() => _previousSection?.call();

  /// Navigates to a resolved nested contents entry.
  void goTo(TextPosition position) => _goTo?.call(position);

  /// Restores an external committed anchor through layout and its first frame.
  /// Restoration never writes viewport progress back over narration commits.
  Future<void> restore(TextPosition position) async {
    await _restore?.call(position);
  }
}
