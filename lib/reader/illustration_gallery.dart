import 'dart:io';

import 'package:flutter/material.dart';

import '../app/reader_controller.dart';
import '../catalog/catalog_book.dart';
import '../illustrations/illustration_exception.dart';
import '../illustrations/illustration_scene.dart';
import '../illustrations/illustration_selection.dart';
import 'illustration_consent_dialog.dart';
import 'illustration_scene_dialog.dart';

/// Unlocked-only gallery; queued and locked scenes have no revealing UI.
class IllustrationGallery extends StatelessWidget {
  /// Creates a gallery subscribed to the shared controller for [book].
  const IllustrationGallery({
    super.key,
    required this.book,
    required this.controller,
  });

  /// Catalog record whose unlocked scenes are presented.
  final CatalogBook book;

  /// Shared application owner of scene updates and deletion.
  final ReaderController controller;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .78,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final scenes = controller.illustrations
              .manifestFor(book)
              .unlockedScenes;
          return Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Text(
                  'Illustrated scenes',
                  style: TextStyle(
                    fontFamily: 'Lora',
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: controller.illustrations.busy
                    ? null
                    : () => _showSettings(context),
                icon: const Icon(Icons.tune),
                label: const Text('Illustration settings'),
              ),
              Expanded(
                child: scenes.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text(
                            'Scenes will appear here after you read past them.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(16),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 360,
                              childAspectRatio: 1.15,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                            ),
                        itemCount: scenes.length,
                        itemBuilder: (context, index) {
                          final scene = scenes[index];
                          final path =
                              scene.localThumbnailPath ?? scene.localImagePath;
                          return Card(
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: path == null
                                  ? null
                                  : () => _showScene(context, scene),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child:
                                        path != null && File(path).existsSync()
                                        ? Semantics(
                                            image: true,
                                            label:
                                                scene.altText ??
                                                'Generated scene illustration',
                                            child: Image.file(
                                              File(path),
                                              fit: BoxFit.cover,
                                              cacheWidth:
                                                  (360 *
                                                          MediaQuery.devicePixelRatioOf(
                                                            context,
                                                          ))
                                                      .ceil(),
                                            ),
                                          )
                                        : const Center(
                                            child: Icon(Icons.broken_image),
                                          ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Text(
                                      scene.caption?.isNotEmpty == true
                                          ? scene.caption!
                                          : 'Scene illustration',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    ),
  );

  Future<void> _showScene(BuildContext context, IllustrationScene scene) async {
    final path = scene.localImagePath;
    if (path == null || !File(path).existsSync()) return;
    final action = await showDialog<IllustrationSceneAction>(
      context: context,
      builder: (context) => IllustrationSceneDialog(scene: scene),
    );
    try {
      if (action == IllustrationSceneAction.delete) {
        await controller.illustrations.deleteScene(book, scene);
      } else if (action == IllustrationSceneAction.regenerate) {
        await controller.illustrations.regenerate(book, scene);
      }
    } on Object catch (error) {
      if (context.mounted) _showError(context, error);
    }
  }

  Future<void> _showSettings(BuildContext context) async {
    try {
      final setup = await controller.illustrations.beginSetup(book);
      if (!context.mounted) return;
      final selection = await showDialog<IllustrationSelection>(
        context: context,
        builder: (_) => IllustrationSettingsDialog(setup: setup),
      );
      if (selection == null || !context.mounted) return;
      await controller.illustrations.updateSettings(
        book,
        setup: setup,
        selection: selection,
      );
    } on Object catch (error) {
      if (context.mounted) _showError(context, error);
    }
  }

  void _showError(BuildContext context, Object error) {
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
}
