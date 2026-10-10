// Persisted field meanings and lifecycle invariants are documented per model.
// ignore_for_file: public_member_api_docs

import 'chapter_text_index.dart';

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
