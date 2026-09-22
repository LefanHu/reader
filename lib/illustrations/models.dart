// Persisted field meanings and lifecycle invariants are documented per model.
// ignore_for_file: public_member_api_docs

/// Lifecycle states for a generated scene stored outside the source EPUB.
enum IllustrationSceneState {
  queued,
  generating,
  readyLocked,
  unlocked,
  hidden,
  failed,
  skippedSafety,
}

/// Reader-confirmed illustration settings for one publication.
class IllustrationProfile {
  const IllustrationProfile({
    required this.enabled,
    required this.style,
    required this.density,
    required this.styleVersion,
    required this.cloudBookId,
    this.analysisVersion = 2,
  });

  final bool enabled;
  final String style;
  final int density;
  final int styleVersion;

  /// Structured world-model schema used by newly scheduled chapter jobs.
  final int analysisVersion;
  final String cloudBookId;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'style': style,
    'density': density,
    'styleVersion': styleVersion,
    'analysisVersion': analysisVersion,
    'cloudBookId': cloudBookId,
  };

  factory IllustrationProfile.fromJson(Map<String, dynamic> json) =>
      IllustrationProfile(
        enabled: json['enabled'] as bool? ?? false,
        style: json['style'] as String? ?? '',
        density: (json['density'] as num?)?.round().clamp(1, 3) ?? 2,
        styleVersion: (json['styleVersion'] as num?)?.round() ?? 1,
        // Existing profiles adopt the current analyzer for newly scheduled
        // chapters; already-created job IDs remain untouched and idempotent.
        analysisVersion: (json['analysisVersion'] as num?)?.round() ?? 2,
        cloudBookId: json['cloudBookId'] as String? ?? '',
      );
}

/// Stable paragraph extracted from one XHTML spine resource.
class IndexedParagraph {
  const IndexedParagraph({
    required this.id,
    required this.text,
    required this.cssSelector,
    required this.ordinal,
    required this.progression,
  });

  final String id;
  final String text;
  final String cssSelector;
  final int ordinal;
  final double progression;

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'cssSelector': cssSelector,
    'ordinal': ordinal,
    'progression': progression,
  };

  factory IndexedParagraph.fromJson(Map<String, dynamic> json) =>
      IndexedParagraph(
        id: json['id'] as String,
        text: json['text'] as String,
        cssSelector: json['cssSelector'] as String,
        ordinal: (json['ordinal'] as num).round(),
        progression: (json['progression'] as num).toDouble().clamp(0, 1),
      );
}

/// Ordered text and DOM mapping for one EPUB spine resource.
class ChapterTextIndex {
  const ChapterTextIndex({
    required this.href,
    required this.spineOrdinal,
    required this.title,
    required this.paragraphs,
    this.language,
  });

  final String href;
  final int spineOrdinal;
  final String? title;
  final String? language;
  final List<IndexedParagraph> paragraphs;

  Map<String, dynamic> toJson() => {
    'href': href,
    'spineOrdinal': spineOrdinal,
    if (title != null) 'title': title,
    if (language != null) 'language': language,
    'paragraphs': paragraphs.map((item) => item.toJson()).toList(),
  };

  factory ChapterTextIndex.fromJson(Map<String, dynamic> json) =>
      ChapterTextIndex(
        href: json['href'] as String,
        spineOrdinal: (json['spineOrdinal'] as num).round(),
        title: json['title'] as String?,
        language: json['language'] as String?,
        paragraphs: (json['paragraphs'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map(
              (item) => IndexedParagraph.fromJson(item.cast<String, dynamic>()),
            )
            .toList(),
      );
}

/// Versioned, local-only index used to submit bounded chapter prose.
class BookTextIndex {
  const BookTextIndex({
    required this.bookHash,
    required this.chapters,
    this.version = 1,
  });

  final int version;
  final String bookHash;
  final List<ChapterTextIndex> chapters;

  Map<String, dynamic> toJson() => {
    'version': version,
    'bookHash': bookHash,
    'chapters': chapters.map((chapter) => chapter.toJson()).toList(),
  };

  factory BookTextIndex.fromJson(Map<String, dynamic> json) => BookTextIndex(
    version: (json['version'] as num?)?.round() ?? 1,
    bookHash: json['bookHash'] as String,
    chapters: (json['chapters'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => ChapterTextIndex.fromJson(item.cast<String, dynamic>()))
        .toList(),
  );

  ChapterTextIndex? chapterForHref(String href) {
    final normalized = href.split('#').first;
    for (final chapter in chapters) {
      if (chapter.href.split('#').first == normalized) return chapter;
    }
    return null;
  }
}

/// Conservative release point at the end of a scene's source passage.
class SceneAnchor {
  const SceneAnchor({
    required this.href,
    required this.spineOrdinal,
    required this.paragraphId,
    required this.cssSelector,
    required this.fallbackProgression,
  });

  final String href;
  final int spineOrdinal;
  final String paragraphId;
  final String cssSelector;
  final double fallbackProgression;

  Map<String, dynamic> toJson() => {
    'href': href,
    'spineOrdinal': spineOrdinal,
    'paragraphId': paragraphId,
    'cssSelector': cssSelector,
    'fallbackProgression': fallbackProgression,
  };

  factory SceneAnchor.fromJson(Map<String, dynamic> json) => SceneAnchor(
    href: json['href'] as String,
    spineOrdinal: (json['spineOrdinal'] as num).round(),
    paragraphId: json['paragraphId'] as String,
    cssSelector: json['cssSelector'] as String? ?? '',
    fallbackProgression:
        (json['fallbackProgression'] as num?)?.toDouble().clamp(0, 1) ?? 1,
  );
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

/// Durable jobs and scenes for one book; stored separately from the catalog.
class IllustrationManifest {
  const IllustrationManifest({
    required this.bookHash,
    this.profile,
    this.chapterJobs = const {},
    this.scenes = const [],
    this.visualBibleVersion = 0,
    this.version = 1,
  });

  final int version;
  final String bookHash;
  final IllustrationProfile? profile;
  final Map<int, String> chapterJobs;
  final List<IllustrationScene> scenes;
  final int visualBibleVersion;

  bool get enabled => profile?.enabled ?? false;
  List<IllustrationScene> get unlockedScenes =>
      scenes.where((scene) => scene.available).toList();

  IllustrationManifest copyWith({
    IllustrationProfile? profile,
    Map<int, String>? chapterJobs,
    List<IllustrationScene>? scenes,
    int? visualBibleVersion,
  }) => IllustrationManifest(
    version: version,
    bookHash: bookHash,
    profile: profile ?? this.profile,
    chapterJobs: chapterJobs ?? this.chapterJobs,
    scenes: scenes ?? this.scenes,
    visualBibleVersion: visualBibleVersion ?? this.visualBibleVersion,
  );

  Map<String, dynamic> toJson() => {
    'version': version,
    'bookHash': bookHash,
    if (profile != null) 'profile': profile!.toJson(),
    'chapterJobs': chapterJobs.map(
      (key, value) => MapEntry(key.toString(), value),
    ),
    'scenes': scenes.map((scene) => scene.toJson()).toList(),
    'visualBibleVersion': visualBibleVersion,
  };

  factory IllustrationManifest.fromJson(Map<String, dynamic> json) =>
      IllustrationManifest(
        version: (json['version'] as num?)?.round() ?? 1,
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
        visualBibleVersion: (json['visualBibleVersion'] as num?)?.round() ?? 0,
      );
}
