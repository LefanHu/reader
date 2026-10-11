import 'package:flutter/material.dart';

import 'session.dart';

/// Compact live playback status shared by reader chrome and the mini-player.
/// It owns no playback resources and scales down inside reserved chrome without
/// changing the text viewport's geometry or hiding the spoken status.
class NarrationStatusIndicator extends StatelessWidget {
  /// Reads a snapshot from the sole shared controller's narration session.
  const NarrationStatusIndicator({super.key, required this.status});

  /// Actual session state, including buffering that has not loaded audio yet.
  final NarrationStatus status;

  /// Stable spoken labels used by native accessibility and reader assertions.
  static String labelFor(NarrationStatus status) => switch (status) {
    NarrationStatus.idle => 'Narration idle',
    NarrationStatus.paused => 'Narration paused',
    NarrationStatus.buffering => 'Narration buffering',
    NarrationStatus.playing => 'Narration playing',
    NarrationStatus.complete => 'Narration complete',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final icon = switch (status) {
      NarrationStatus.playing => Icons.graphic_eq,
      NarrationStatus.buffering => Icons.hourglass_top,
      NarrationStatus.complete => Icons.check_circle_outline,
      NarrationStatus.paused => Icons.pause_circle_outline,
      NarrationStatus.idle => Icons.headphones,
    };
    return Semantics(
      label: labelFor(status),
      liveRegion: true,
      child: ExcludeSemantics(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: colors.primary),
              const SizedBox(width: 6),
              Text(
                labelFor(status),
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: colors.onSurface),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
