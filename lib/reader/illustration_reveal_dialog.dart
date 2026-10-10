import 'dart:io';

import 'package:flutter/material.dart';

import '../illustrations/illustration_scene.dart';

/// Result of a newly revealed scene, distinct from gallery deletion.
enum IllustrationRevealAction {
  /// Returns to reading.
  continueReading,

  /// Hides the scene without deleting it.
  hide,

  /// Requests a replacement illustration.
  regenerate,
}

/// Presents a newly unlocked scene; the shell owns marking and result handling.
class IllustrationRevealDialog extends StatelessWidget {
  /// Creates the presentation for a scene whose local image was checked.
  const IllustrationRevealDialog({super.key, required this.scene});

  /// Unlocked scene with an existing local image.
  final IllustrationScene scene;

  @override
  Widget build(BuildContext context) => Dialog(
    clipBehavior: Clip.antiAlias,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            image: true,
            label: scene.altText ?? 'Generated scene illustration',
            child: Image.file(File(scene.localImagePath!), fit: BoxFit.contain),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              scene.caption?.isNotEmpty == true
                  ? scene.caption!
                  : 'A scene you just read',
              style: const TextStyle(
                fontFamily: 'Lora',
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () =>
                      Navigator.pop(context, IllustrationRevealAction.hide),
                  child: const Text('Hide'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(
                    context,
                    IllustrationRevealAction.regenerate,
                  ),
                  child: const Text('Regenerate'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    IllustrationRevealAction.continueReading,
                  ),
                  child: const Text('Continue reading'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
