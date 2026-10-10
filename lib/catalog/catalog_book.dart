import '../text/text_position.dart';

/// Durable metadata and reading state for one locally stored EPUB or TXT book.
///
/// [lastPosition] identifies normalized text rather than a derived page number,
/// allowing the same passage to be restored in either layout.
class CatalogBook {
  /// Creates a durable catalog record from imported publication metadata.
  const CatalogBook({
    required this.hash,
    required this.fileName,
    required this.path,
    required this.title,
    required this.authors,
    required this.addedAt,
    this.identifier,
    this.language,
    this.coverPath,
    this.wordCount,
    this.lastPosition,
    this.progress = 0,
    this.lastOpenedAt,
  });

  /// SHA-256 of the source bytes, used as its storage key and duplicate ID.
  final String hash;

  /// Original filename shown in import results and diagnostics.
  final String fileName;

  /// Private application-support path to the copied EPUB or TXT source.
  final String path;

  /// Display title from publication metadata or the source filename.
  final String title;

  /// Normalized author names from publication metadata.
  final List<String> authors;

  /// Publication identifier when the EPUB provides one.
  final String? identifier;

  /// Primary publication language when available.
  final String? language;

  /// Cached local cover path, or `null` for a generated cover.
  final String? coverPath;

  /// Approximate normalized-text word count; absent until older books backfill.
  /// This additive field does not change document identities or catalog version.
  final int? wordCount;

  /// Leading normalized text position, independent of typography and viewport.
  final TextPosition? lastPosition;

  /// Publication-wide progress normalized to the inclusive range 0–1.
  final double progress;

  /// Time at which this book was committed to the catalog.
  final DateTime addedAt;

  /// Most recent reader entry or position update.
  final DateTime? lastOpenedAt;

  /// Human-readable author metadata with a reliable empty-metadata fallback.
  String get authorLine =>
      authors.isEmpty ? 'Unknown author' : authors.join(', ');

  /// Whether the user has opened or advanced into this publication.
  bool get started => lastPosition != null || progress > 0;

  /// Treats the final half-percent as complete to absorb position rounding.
  bool get finished => progress >= 0.995;

  /// Returns a new record with mutable reading-state fields replaced.
  CatalogBook copyWith({
    int? wordCount,
    String? coverPath,
    TextPosition? lastPosition,
    double? progress,
    DateTime? lastOpenedAt,
  }) => CatalogBook(
    hash: hash,
    fileName: fileName,
    path: path,
    title: title,
    authors: authors,
    identifier: identifier,
    language: language,
    coverPath: coverPath ?? this.coverPath,
    wordCount: wordCount ?? this.wordCount,
    lastPosition: lastPosition ?? this.lastPosition,
    progress: progress ?? this.progress,
    addedAt: addedAt,
    lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
  );

  /// Serializes the catalog record; dates are normalized to UTC.
  Map<String, dynamic> toJson() => {
    'hash': hash,
    'fileName': fileName,
    'path': path,
    'title': title,
    'authors': authors,
    if (identifier != null) 'identifier': identifier,
    if (language != null) 'language': language,
    if (coverPath != null) 'coverPath': coverPath,
    if (wordCount != null) 'wordCount': wordCount,
    if (lastPosition != null) 'lastPosition': lastPosition!.toJson(),
    'progress': progress,
    'addedAt': addedAt.toUtc().toIso8601String(),
    if (lastOpenedAt != null)
      'lastOpenedAt': lastOpenedAt!.toUtc().toIso8601String(),
  };

  /// Reconstructs a record and clamps malformed progress values safely.
  factory CatalogBook.fromJson(Map<String, dynamic> json) => CatalogBook(
    hash: json['hash'] as String,
    fileName: json['fileName'] as String,
    path: json['path'] as String,
    title: json['title'] as String,
    authors: (json['authors'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList(),
    identifier: json['identifier'] as String?,
    language: json['language'] as String?,
    coverPath: json['coverPath'] as String?,
    wordCount: json['wordCount'] is int && (json['wordCount'] as int) >= 0
        ? json['wordCount'] as int
        : null,
    lastPosition: json['lastPosition'] == null
        ? null
        : TextPosition.fromJson(
            (json['lastPosition'] as Map).cast<String, dynamic>(),
          ),
    progress: ((json['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1),
    addedAt: DateTime.parse(json['addedAt'] as String),
    lastOpenedAt: json['lastOpenedAt'] == null
        ? null
        : DateTime.parse(json['lastOpenedAt'] as String),
  );
}
