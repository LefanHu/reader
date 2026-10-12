import 'illustration_scene.dart';

/// Progress of one inline illustration slot. Ordered by priority: a later
/// stage wins when several scenes share an anchor block.
enum IllustrationFigureStage {
  /// The server confirmed the scene and is generating its image.
  generating,

  /// The image is ready on the server and is being downloaded locally.
  downloading,

  /// The image is on disk and renders in place of the placeholder.
  ready,
}

/// A scene rendered after its anchor block, with its current [stage].
class IllustrationFigure {
  /// Pairs [scene] with the stage derived from its lifecycle state.
  const IllustrationFigure(this.scene, this.stage);

  /// Scene owning the slot; its image path is set only when [stage] is ready.
  final IllustrationScene scene;

  /// Which progress presentation the slot shows.
  final IllustrationFigureStage stage;
}

/// Groups visible scenes by section ID (`anchor.href`), then anchor block ID.
///
/// Hidden, failed, queued and safety-skipped scenes are excluded so they
/// reserve no space. When several scenes anchor the same block the furthest
/// stage wins; ties go to the smaller scene ID so layout is deterministic.
Map<String, Map<String, IllustrationFigure>> illustrationFigures(
  Iterable<IllustrationScene> scenes,
) {
  final figures = <String, Map<String, IllustrationFigure>>{};
  for (final scene in scenes) {
    final stage = switch (scene.state) {
      IllustrationSceneState.unlocked when scene.localImagePath != null =>
        IllustrationFigureStage.ready,
      IllustrationSceneState.readyLocked => IllustrationFigureStage.downloading,
      IllustrationSceneState.generating => IllustrationFigureStage.generating,
      _ => null,
    };
    if (stage == null) continue;
    final blocks = figures.putIfAbsent(scene.anchor.href, () => {});
    final existing = blocks[scene.anchor.paragraphId];
    if (existing == null ||
        stage.index > existing.stage.index ||
        (stage == existing.stage &&
            scene.id.compareTo(existing.scene.id) < 0)) {
      blocks[scene.anchor.paragraphId] = IllustrationFigure(scene, stage);
    }
  }
  return figures;
}
