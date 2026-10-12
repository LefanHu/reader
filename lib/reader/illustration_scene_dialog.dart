import 'dart:io';

import 'package:flutter/material.dart';

import '../app/reader_controller.dart';
import '../catalog/catalog_book.dart';
import '../illustrations/illustration_exception.dart';
import '../illustrations/illustration_scene.dart';

/// Result of an existing scene presentation, including permanent deletion.
enum IllustrationSceneAction {
  /// Closes the presentation without changing the scene.
  close,

  /// Deletes the scene rather than hiding it.
  delete,

  /// Requests a replacement illustration.
  regenerate,

  /// Removes the scene from the page while keeping it in the gallery.
  hide,

  /// Returns a hidden scene to the page.
  unhide,

  /// Jumps the reader to the scene's anchor paragraph.
  goTo,
}

/// Presents a downloaded scene; [showIllustrationScene] owns result handling.
class IllustrationSceneDialog extends StatelessWidget {
  /// Creates the presentation for a scene whose local image was checked.
  const IllustrationSceneDialog({
    super.key,
    required this.scene,
    required this.canGoTo,
  });

  /// Downloaded scene with an existing local image.
  final IllustrationScene scene;

  /// Whether a jump action is offered; false when already reading the scene.
  final bool canGoTo;

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
      if (scene.state == IllustrationSceneState.hidden)
        TextButton(
          onPressed: () =>
              Navigator.pop(context, IllustrationSceneAction.unhide),
          child: const Text('Show on page'),
        )
      else
        TextButton(
          onPressed: () => Navigator.pop(context, IllustrationSceneAction.hide),
          child: const Text('Hide from page'),
        ),
      if (canGoTo)
        TextButton(
          onPressed: () => Navigator.pop(context, IllustrationSceneAction.goTo),
          child: const Text('Go to scene'),
        ),
      FilledButton(
        onPressed: () => Navigator.pop(context, IllustrationSceneAction.close),
        child: const Text('Close'),
      ),
    ],
  );
}

/// Shows [scene] and applies the chosen action through the shared controller.
///
/// Returns true only when the reader chose "Go to scene"; the caller owns the
/// navigation. Returns false without a dialog when the local image is missing.
/// Failures surface as a SnackBar and never interrupt reading.
Future<bool> showIllustrationScene(
  BuildContext context,
  ReaderController controller,
  CatalogBook book,
  IllustrationScene scene, {
  required bool canGoTo,
}) async {
  final path = scene.localImagePath;
  if (path == null || !File(path).existsSync()) return false;
  final action = await showDialog<IllustrationSceneAction>(
    context: context,
    builder: (context) =>
        IllustrationSceneDialog(scene: scene, canGoTo: canGoTo),
  );
  try {
    switch (action) {
      case IllustrationSceneAction.delete:
        await controller.illustrations.deleteScene(book, scene);
      case IllustrationSceneAction.regenerate:
        await controller.illustrations.regenerate(book, scene);
      case IllustrationSceneAction.hide:
        await controller.illustrations.hide(book, scene);
      case IllustrationSceneAction.unhide:
        await controller.illustrations.unhide(book, scene);
      case IllustrationSceneAction.goTo:
        return true;
      case IllustrationSceneAction.close || null:
        break;
    }
  } on Object catch (error) {
    if (context.mounted) showIllustrationError(context, error);
  }
  return false;
}

/// Presents an auxiliary illustration failure without interrupting reading.
void showIllustrationError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        error is IllustrationException
            ? error.message
            : 'Illustrations could not be updated. Try again when connected.',
      ),
    ),
  );
}
