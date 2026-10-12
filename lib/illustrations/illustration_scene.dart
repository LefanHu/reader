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
    this.regenerating = false,
    this.pendingGenerationVersion,
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

  /// Last locally committed image version, not the newest server recipe.
  final int generationVersion;

  /// Remote generation progress, independent of committed spoiler/reveal state.
  final bool regenerating;

  /// Newer ready server version awaiting a passed gate and atomic local commit.
  /// Null means no replacement is awaiting download; it never owns local paths.
  final int? pendingGenerationVersion;
  final String? failureCategory;
  final bool automaticRevealDismissed;

  bool get available =>
      state == IllustrationSceneState.unlocked ||
      state == IllustrationSceneState.hidden;

  static const _unchanged = Object();

  /// Omitted nullable fields retain their values; explicit null clears them.
  /// Replacements preserve committed paths/version/reveal until manifest commit.
  IllustrationScene copyWith({
    IllustrationSceneState? state,
    Object? localImagePath = _unchanged,
    Object? localThumbnailPath = _unchanged,
    Object? altText = _unchanged,
    Object? caption = _unchanged,
    int? generationVersion,
    bool? regenerating,
    Object? pendingGenerationVersion = _unchanged,
    Object? failureCategory = _unchanged,
    bool? automaticRevealDismissed,
  }) => IllustrationScene(
    id: id,
    jobId: jobId,
    anchor: anchor,
    state: state ?? this.state,
    localImagePath: identical(localImagePath, _unchanged)
        ? this.localImagePath
        : localImagePath as String?,
    localThumbnailPath: identical(localThumbnailPath, _unchanged)
        ? this.localThumbnailPath
        : localThumbnailPath as String?,
    altText: identical(altText, _unchanged) ? this.altText : altText as String?,
    caption: identical(caption, _unchanged) ? this.caption : caption as String?,
    generationVersion: generationVersion ?? this.generationVersion,
    regenerating: regenerating ?? this.regenerating,
    pendingGenerationVersion: identical(pendingGenerationVersion, _unchanged)
        ? this.pendingGenerationVersion
        : pendingGenerationVersion as int?,
    failureCategory: identical(failureCategory, _unchanged)
        ? this.failureCategory
        : failureCategory as String?,
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
    'regenerating': regenerating,
    if (pendingGenerationVersion != null)
      'pendingGenerationVersion': pendingGenerationVersion,
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
        regenerating: json['regenerating'] as bool? ?? false,
        pendingGenerationVersion: json['pendingGenerationVersion'] as int?,
        failureCategory: json['failureCategory'] as String?,
        automaticRevealDismissed:
            json['automaticRevealDismissed'] as bool? ?? false,
      );
}
