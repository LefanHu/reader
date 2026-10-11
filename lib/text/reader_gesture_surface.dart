import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../preferences/reading_mode.dart';

/// Keeps touch page navigation separate from precise-pointer text selection.
/// Mouse drags belong to SelectionArea; taps and touch curls retain reader behavior.
class ReaderGestureSurface extends StatelessWidget {
  /// Receives viewport-owned navigation/turn callbacks without owning resources.
  const ReaderGestureSurface({
    super.key,
    required this.mode,
    required this.selecting,
    required this.width,
    required this.rightToLeft,
    required this.onStep,
    required this.onTap,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
    required this.child,
  });

  /// Active page mode, never Scroll.
  final ReadingMode mode;

  /// Selection excludes navigation until it is cleared or explicitly replaced.
  final bool selecting;

  /// Measured content width for stationary edge-tap hit regions.
  final double width;

  /// Logical reading direction used for edge taps and directional swipes.
  final bool rightToLeft;

  /// Explicit relative page navigation and chrome toggle owned by the viewport.
  final ValueChanged<int> onStep;

  /// Toggles chrome when a non-selection tap misses the page-edge regions.
  final VoidCallback onTap;

  /// Borrowed curl gesture callbacks; the viewport owns textures and animation.
  final GestureDragStartCallback onDragStart;

  /// Updates the viewport-owned touch curl without committing its preview.
  final GestureDragUpdateCallback onDragUpdate;

  /// Lets the viewport decide whether the released touch turn can commit.
  final GestureDragEndCallback onDragEnd;

  /// Cancels an unfinished touch turn and releases its preview resources.
  final GestureDragCancelCallback onDragCancel;

  /// The actual committed page, its selection region, and optional curl preview.
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapUp: selecting
        ? null
        : (details) {
            if (mode == ReadingMode.pageFlip) {
              final fraction = details.localPosition.dx / width;
              if (fraction < .2 || fraction > .8) {
                onStep((fraction > .8) != rightToLeft ? 1 : -1);
                return;
              }
            }
            onTap();
          },
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      supportedDevices: const {
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.trackpad,
      },
      dragStartBehavior: mode == ReadingMode.pageFlip
          ? DragStartBehavior.down
          : DragStartBehavior.start,
      onHorizontalDragStart: !selecting && mode == ReadingMode.pageFlip
          ? onDragStart
          : null,
      onHorizontalDragUpdate: !selecting && mode == ReadingMode.pageFlip
          ? onDragUpdate
          : null,
      onHorizontalDragCancel: !selecting && mode == ReadingMode.pageFlip
          ? onDragCancel
          : null,
      onHorizontalDragEnd: selecting
          ? null
          : mode == ReadingMode.pageFlip
          ? onDragEnd
          : (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity.abs() > 80) {
                onStep((velocity < 0) != rightToLeft ? 1 : -1);
              }
            },
      child: child,
    ),
  );
}
