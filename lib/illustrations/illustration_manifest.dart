// Persisted field meanings and lifecycle invariants are documented per model.
// ignore_for_file: public_member_api_docs

import 'illustration_profile.dart';
import 'illustration_scene.dart';

/// Durable jobs and scenes for one book; stored separately from the catalog.
class IllustrationManifest {
  const IllustrationManifest({
    required this.bookHash,
    this.profile,
    this.chapterJobs = const {},
    this.scenes = const [],
  });

  final String bookHash;
  final IllustrationProfile? profile;
  final Map<int, String> chapterJobs;
  final List<IllustrationScene> scenes;

  bool get enabled => profile?.enabled ?? false;
  List<IllustrationScene> get unlockedScenes =>
      scenes.where((scene) => scene.available).toList();

  IllustrationManifest copyWith({
    IllustrationProfile? profile,
    Map<int, String>? chapterJobs,
    List<IllustrationScene>? scenes,
  }) => IllustrationManifest(
    bookHash: bookHash,
    profile: profile ?? this.profile,
    chapterJobs: chapterJobs ?? this.chapterJobs,
    scenes: scenes ?? this.scenes,
  );

  Map<String, dynamic> toJson() => {
    'bookHash': bookHash,
    if (profile != null) 'profile': profile!.toJson(),
    'chapterJobs': chapterJobs.map(
      (key, value) => MapEntry(key.toString(), value),
    ),
    'scenes': scenes.map((scene) => scene.toJson()).toList(),
  };

  factory IllustrationManifest.fromJson(Map<String, dynamic> json) =>
      IllustrationManifest(
        bookHash: json['bookHash'] as String,
        profile: json['profile'] == null
            ? null
            : IllustrationProfile.fromJson(
                (json['profile'] as Map).cast<String, dynamic>(),
              ),
        chapterJobs: (json['chapterJobs'] as Map? ?? const {}).map(
          (key, value) => MapEntry(int.parse(key.toString()), value as String),
        ),
        scenes: (json['scenes'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map(
              (item) =>
                  IllustrationScene.fromJson(item.cast<String, dynamic>()),
            )
            .toList(),
      );
}
