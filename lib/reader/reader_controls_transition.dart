import 'package:flutter/material.dart';

/// Animates chrome inside fixed slots without changing viewport constraints.
/// Hidden controls stop accepting input, focus, and semantics immediately,
/// even while their last visible pixels are still fading out.
class ReaderControlsTransition extends StatelessWidget {
  /// Creates a transition that immediately excludes hidden interaction.
  const ReaderControlsTransition({
    super.key,
    required this.visible,
    required this.child,
    this.hiddenOffset = Offset.zero,
  });

  /// Whether the controls accept interaction and appear in semantics.
  final bool visible;

  /// Controls hosted inside the fixed chrome slot.
  final Widget child;

  /// Slide offset used while the controls are hidden.
  final Offset hiddenOffset;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    return ClipRect(
      child: IgnorePointer(
        ignoring: !visible,
        child: ExcludeSemantics(
          excluding: !visible,
          child: ExcludeFocus(
            excluding: !visible,
            child: AnimatedSlide(
              offset: visible ? Offset.zero : hiddenOffset,
              duration: duration,
              curve: Curves.easeOut,
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: duration,
                curve: Curves.easeOut,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
