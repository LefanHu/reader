import 'dart:io';

import 'package:flutter/material.dart';

import '../illustrations/illustration_scene.dart';

/// Result of an existing gallery scene, including permanent scene deletion.
enum IllustrationSceneAction {
  /// Closes the presentation without changing the scene.
  close,

  /// Deletes the scene rather than hiding it.
  delete,

  /// Requests a replacement illustration.
  regenerate,
}

/// Presents an unlocked gallery scene; the gallery owns result handling.
class IllustrationSceneDialog extends StatelessWidget {
  /// Creates the presentation for a scene whose local image was checked.
  const IllustrationSceneDialog({super.key, required this.scene});

  /// Unlocked scene with an existing local image.
  final IllustrationScene scene;

  @override
  Widget build(BuildContext context) => AlertDialog(
    contentPadding: EdgeInsets.zero,
    content: Semantics(
      image: true,
      label: scene.altText ?? 'Generated scene illustration',
      child: Image.file(File(scene.localImagePath!), fit: BoxFit.contain),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, IllustrationSceneAction.delete),
        child: const Text('Delete'),
      ),
      TextButton(
        onPressed: () =>
            Navigator.pop(context, IllustrationSceneAction.regenerate),
        child: const Text('Regenerate'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, IllustrationSceneAction.close),
        child: const Text('Close'),
      ),
    ],
  );
}
