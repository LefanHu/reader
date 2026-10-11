import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Maps paging keys to reading steps, respecting right-to-left text.
class ReaderKeyNavigation extends StatelessWidget {
  /// Wraps [child] in an autofocused key handler.
  const ReaderKeyNavigation({
    super.key,
    required this.enabled,
    required this.rightToLeft,
    required this.onStep,
    required this.child,
  });

  /// Whether keys are handled; false lets selection own the keyboard.
  final bool enabled;

  /// Whether the logical forward arrow is the left arrow.
  final bool rightToLeft;

  /// Receives +1 for forward and -1 for backward.
  final ValueChanged<int> onStep;

  /// Reader content below the handler.
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (_, event) {
      if (!enabled || event is! KeyDownEvent) return KeyEventResult.ignored;
      final key = event.logicalKey;
      final forward = rightToLeft
          ? LogicalKeyboardKey.arrowLeft
          : LogicalKeyboardKey.arrowRight;
      final back = rightToLeft
          ? LogicalKeyboardKey.arrowRight
          : LogicalKeyboardKey.arrowLeft;
      if (key == LogicalKeyboardKey.pageDown ||
          key == LogicalKeyboardKey.space ||
          key == forward) {
        onStep(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.pageUp || key == back) {
        onStep(-1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: child,
  );
}
