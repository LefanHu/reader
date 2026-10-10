// Persisted field meanings and lifecycle invariants are documented per model.
// ignore_for_file: public_member_api_docs

import 'scene_anchor.dart';

/// Lifecycle states for a generated scene stored outside the source book.
enum IllustrationSceneState {
  queued,
  generating,
  readyLocked,
  unlocked,
  hidden,
  failed,
  skippedSafety,
}

/// One server-planned illustration and its spoiler/reveal state.
class IllustrationScene {
  const IllustrationScene({
    required this.id,
    required this.anchor,
    required this.state,
    this.jobId,
    this.localImagePath,
    this.localThumbnailPath,
    this.altText,
    this.caption,
    this.generationVersion = 1,
    this.failureCategory,
    this.automaticRevealDismissed = false,
  });

  final String id;
  final String? jobId;
  final SceneAnchor anchor;
  final IllustrationSceneState state;
  final String? localImagePath;
  final String? localThumbnailPath;
  final String? altText;
  final String? caption;
  final int generationVersion;
  final String? failureCategory;
  final bool automaticRevealDismissed;

  bool get available =>
      state == IllustrationSceneState.unlocked ||
      state == IllustrationSceneState.hidden;

  IllustrationScene copyWith({
    IllustrationSceneState? state,
    String? localImagePath,
    String? localThumbnailPath,
    String? altText,
    String? caption,
    int? generationVersion,
    String? failureCategory,
    bool? automaticRevealDismissed,
  }) => IllustrationScene(
    id: id,
    jobId: jobId,
    anchor: anchor,
    state: state ?? this.state,
    localImagePath: localImagePath ?? this.localImagePath,
    localThumbnailPath: localThumbnailPath ?? this.localThumbnailPath,
    altText: altText ?? this.altText,
    caption: caption ?? this.caption,
    generationVersion: generationVersion ?? this.generationVersion,
    failureCategory: failureCategory ?? this.failureCategory,
    automaticRevealDismissed:
        automaticRevealDismissed ?? this.automaticRevealDismissed,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    if (jobId != null) 'jobId': jobId,
    'anchor': anchor.toJson(),
    'state': state.name,
    if (localImagePath != null) 'localImagePath': localImagePath,
    if (localThumbnailPath != null) 'localThumbnailPath': localThumbnailPath,
    if (altText != null) 'altText': altText,
    if (caption != null) 'caption': caption,
    'generationVersion': generationVersion,
    if (failureCategory != null) 'failureCategory': failureCategory,
    'automaticRevealDismissed': automaticRevealDismissed,
  };

  factory IllustrationScene.fromJson(Map<String, dynamic> json) =>
      IllustrationScene(
        id: json['id'] as String,
        jobId: json['jobId'] as String?,
        anchor: SceneAnchor.fromJson(
          (json['anchor'] as Map).cast<String, dynamic>(),
        ),
        state: IllustrationSceneState.values.byName(
          json['state'] as String? ?? 'queued',
        ),
        localImagePath: json['localImagePath'] as String?,
        localThumbnailPath: json['localThumbnailPath'] as String?,
        altText: json['altText'] as String?,
        caption: json['caption'] as String?,
        generationVersion: (json['generationVersion'] as num?)?.round() ?? 1,
        failureCategory: json['failureCategory'] as String?,
        automaticRevealDismissed:
            json['automaticRevealDismissed'] as bool? ?? false,
      );
}
