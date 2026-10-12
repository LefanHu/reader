import 'dart:io';

import 'package:flutter/material.dart';

import '../illustrations/illustration_figure.dart';

/// Fills one inline figure slot with a progress placeholder or finished art.
///
/// The slot's size is fixed by the section layout, so stage changes never move
/// text. Progress is determinate (two stages) because providers report nothing
/// finer, which also keeps reduced-motion settings honored.
class IllustrationFigureView extends StatelessWidget {
  /// Creates the view for [figure]; [onOpen] runs when finished art is tapped.
  const IllustrationFigureView({
    super.key,
    required this.figure,
    required this.onOpen,
  });

  /// Scene and progress stage to present.
  final IllustrationFigure figure;

  /// Opens the full scene presentation. Placeholders are not tappable.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scene = figure.scene;
    final path = scene.localImagePath;
    if (figure.stage == IllustrationFigureStage.ready &&
        path != null &&
        File(path).existsSync()) {
      return _ready(context, path);
    }
    // A vanished file degrades to the download placeholder, never a broken icon.
    return _placeholder(
      context,
      figure.stage == IllustrationFigureStage.generating
          ? IllustrationFigureStage.generating
          : IllustrationFigureStage.downloading,
    );
  }

  Widget _ready(BuildContext context, String path) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onOpen,
        child: Semantics(
          image: true,
          button: true,
          label: figure.scene.altText ?? 'Generated scene illustration',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  cacheWidth:
                      (constraints.maxWidth *
                              MediaQuery.devicePixelRatioOf(context))
                          .ceil(),
                ),
                if (figure.scene.regenerating)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: ColoredBox(
                      color: scheme.surface.withValues(alpha: .85),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Creating a new version…'),
                            const SizedBox(height: 6),
                            const LinearProgressIndicator(value: .5),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context, IllustrationFigureStage stage) {
    final scheme = Theme.of(context).colorScheme;
    final generating = stage == IllustrationFigureStage.generating;
    final label = generating
        ? 'Illustrating this scene…'
        : 'Preparing illustration…';
    return Semantics(
      label: '$label Illustration in progress.',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          // Large accessibility text scales the column down instead of
          // overflowing the fixed-height slot.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome, color: scheme.onSurfaceVariant),
                  const SizedBox(height: 8),
                  Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: 200,
                    child: LinearProgressIndicator(
                      value: generating ? .5 : .9,
                      backgroundColor: scheme.onSurface.withValues(alpha: .12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
