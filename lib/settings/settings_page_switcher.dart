import 'package:flutter/material.dart';

/// Animates Settings page changes along the navigation axis.
///
/// Compact layouts slide horizontally with a fade-through: [depth] increasing
/// enters from the end edge, decreasing from the start edge (mirrored in RTL).
/// Wide layouts keep the sidebar fixed, so the detail only fades through with a
/// slight rise. The outgoing page ignores pointers and is hidden from semantics
/// as soon as it starts leaving. Reduced motion swaps pages instantly.
class SettingsPageSwitcher extends StatefulWidget {
  /// [child] must carry a key identifying its page so a change is detected.
  const SettingsPageSwitcher({
    super.key,
    required this.depth,
    required this.horizontal,
    required this.child,
  });

  /// Navigation depth of [child]: 0 for the category list, 1 for a detail.
  final int depth;

  /// Whether pages move along the reading axis (compact) or fade in place.
  final bool horizontal;

  /// The keyed page currently shown.
  final Widget child;

  @override
  State<SettingsPageSwitcher> createState() => _SettingsPageSwitcherState();
}

class _SettingsPageSwitcherState extends State<SettingsPageSwitcher> {
  // Direction of the latest change; retained so outgoing pages finish the same way.
  bool _forward = true;

  @override
  void didUpdateWidget(SettingsPageSwitcher old) {
    super.didUpdateWidget(old);
    if (widget.depth != old.depth) _forward = widget.depth > old.depth;
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.child.key;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : Duration(milliseconds: widget.horizontal ? 300 : 220),
      layoutBuilder: (active, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, ?active]),
      transitionBuilder: (child, animation) => _PageTransition(
        animation: animation,
        incoming: child.key == current,
        // Signed horizontal travel in logical pixels; 0 fades in place.
        travel: widget.horizontal ? (_forward != rtl ? 32.0 : -32.0) : 0,
        child: child,
      ),
      child: widget.child,
    );
  }
}

class _PageTransition extends AnimatedWidget {
  const _PageTransition({
    required Animation<double> animation,
    required this.incoming,
    required this.travel,
    required this.child,
  }) : super(listenable: animation);

  final bool incoming;
  final double travel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Incoming runs 0→1; outgoing runs the same animation in reverse, 1→0.
    final value = (listenable as Animation<double>).value;
    final opacity = incoming
        ? Curves.easeOut.transform(((value - .3) / .7).clamp(0, 1))
        : Curves.easeIn.transform(((value - .7) / .3).clamp(0, 1));
    final eased = Curves.easeOutCubic.transform(value);
    final offset = travel == 0
        ? Offset(0, incoming ? 8 * (1 - eased) : 0)
        : Offset((incoming ? travel : -travel) * (1 - eased), 0);
    return IgnorePointer(
      ignoring: !incoming,
      child: ExcludeSemantics(
        excluding: !incoming,
        child: Opacity(
          opacity: opacity,
          child: Transform.translate(offset: offset, child: child),
        ),
      ),
    );
  }
}
