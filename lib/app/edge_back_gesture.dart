import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Completes Back on release of a rightward physical-left-edge pointer swipe.
/// Interior gestures, edge taps, and vertical scrolling retain normal arbitration.
class EdgeBackGesture extends StatelessWidget {
  /// Wraps an entire routed surface, outside its safe-area padding.
  const EdgeBackGesture({super.key, required this.onBack, required this.child});

  /// Existing screen Back action; called only while the owning route is current.
  final VoidCallback onBack;

  /// Surface retaining its existing hit targets and accessible Back controls.
  final Widget child;

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.translucent,
    excludeFromSemantics: true,
    gestures: {
      _EdgeBackDragRecognizer:
          GestureRecognizerFactoryWithHandlers<_EdgeBackDragRecognizer>(
            () => _EdgeBackDragRecognizer(),
            (recognizer) {
              recognizer
                ..dragStartBehavior = DragStartBehavior.down
                ..onlyAcceptDragOnThreshold = true
                ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
                ..isCurrentRoute = (() =>
                    ModalRoute.of(context)?.isCurrent == true)
                ..onBack = onBack;
            },
          ),
    },
    child: child,
  );
}

/// Tracks one edge pointer without rebuilding or touching reading state on moves.
class _EdgeBackDragRecognizer extends HorizontalDragGestureRecognizer {
  _EdgeBackDragRecognizer() {
    onEnd = (details) {
      final down = _downPosition;
      if (_released &&
          down != null &&
          isCurrentRoute?.call() == true &&
          details.globalPosition.dx - down.dx >= 64) {
        onBack?.call();
      }
    };
  }

  bool Function()? isCurrentRoute;
  VoidCallback? onBack;
  int? _pointer;
  Offset? _downPosition;
  bool _released = false;

  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) => false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    // Admission at DOWN keeps content drags disjoint from the viewport's padding.
    if (_pointer != null ||
        event.position.dx < 0 ||
        event.position.dx >= 20 ||
        isCurrentRoute?.call() != true) {
      return;
    }
    _pointer = event.pointer;
    _downPosition = event.position;
    _released = false;
    super.addAllowedPointer(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind kind,
    double? deviceTouchSlop,
  ) =>
      globalDistanceMoved > 0 &&
      super.hasSufficientGlobalDistanceToAccept(kind, deviceTouchSlop);

  @override
  void handleEvent(PointerEvent event) {
    // The SDK can report onEnd for cancellation after accepting the arena.
    if (event is PointerUpEvent && event.pointer == _pointer) _released = true;
    super.handleEvent(event);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    // onEnd runs inside super and still needs the original DOWN and release flag.
    super.didStopTrackingLastPointer(pointer);
    _pointer = null;
    _downPosition = null;
    _released = false;
  }
}
