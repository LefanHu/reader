/// Controls how reflowable EPUB content moves through the reader viewport.
enum ReadingMode {
  /// One continuous vertical flow.
  scroll,

  /// Discrete horizontally navigated pages.
  pages,
}

/// Color presets translated into Readium background and foreground colors.
enum ReadingTheme {
  /// Neutral ivory paper with dark ink.
  paper,

  /// Warm low-contrast paper with brown ink.
  sepia,

  /// Dark surface with light text.
  dark,
}

/// Library subsets exposed by the compact picker and tablet sidebar.
enum LibraryFilter {
  /// Every imported publication.
  all,

  /// Started publications below the completion threshold.
  reading,

  /// Publications at or above the completion threshold.
  finished,
}

/// Stable sort orders available in the library.
enum LibrarySort {
  /// Most recently opened or imported first.
  recent,

  /// Case-insensitive title order.
  title,
}

/// Reader-wide preferences shared by every imported publication.
///
/// These values are persisted separately from the catalog so changing a book
/// record cannot reset the user's preferred reading experience.
class ReaderSettings {
  /// Creates settings, defaulting to scrolling serif text on paper.
  const ReaderSettings({
    this.mode = ReadingMode.scroll,
    this.theme = ReadingTheme.paper,
    this.fontSize = 100,
    this.serif = true,
  });

  /// Active flow mode.
  final ReadingMode mode;

  /// Active reader color preset.
  final ReadingTheme theme;

  /// Readium font scale as an integer percentage.
  final int fontSize;

  /// Whether Readium should prefer its generic serif family.
  final bool serif;

  /// Returns a new value with only the supplied fields replaced.
  ReaderSettings copyWith({
    ReadingMode? mode,
    ReadingTheme? theme,
    int? fontSize,
    bool? serif,
  }) => ReaderSettings(
    mode: mode ?? this.mode,
    theme: theme ?? this.theme,
    fontSize: fontSize ?? this.fontSize,
    serif: serif ?? this.serif,
  );

  /// Serializes settings into the versioned value stored by [SettingsStore].
  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'theme': theme.name,
    'fontSize': fontSize,
    'serif': serif,
  };

  /// Restores settings while constraining text size to the supported range.
  factory ReaderSettings.fromJson(Map<String, dynamic> json) => ReaderSettings(
    mode: ReadingMode.values.byName(json['mode'] as String? ?? 'scroll'),
    theme: ReadingTheme.values.byName(json['theme'] as String? ?? 'paper'),
    fontSize: (json['fontSize'] as num?)?.round().clamp(80, 180) ?? 100,
    serif: json['serif'] as bool? ?? true,
  );
}

/// Durable metadata and reading state for one locally stored EPUB.
///
/// [lastLocator] contains the complete Readium locator rather than a derived
/// page number, allowing the same passage to be restored in either layout.
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
    this.lastLocator,
    this.progress = 0,
    this.lastOpenedAt,
  });

  /// SHA-256 of the source EPUB, used as its storage key and duplicate ID.
  final String hash;

  /// Original filename shown in import results and diagnostics.
  final String fileName;

  /// Private application-support path to the copied EPUB.
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

  /// Last locator emitted by Readium, preserved without lossy conversion.
  final Map<String, dynamic>? lastLocator;

  /// Publication-wide progress normalized to the inclusive range 0–1.
  final double progress;

  /// Time at which this EPUB was committed to the catalog.
  final DateTime addedAt;

  /// Most recent reader entry or locator update.
  final DateTime? lastOpenedAt;

  /// Human-readable author metadata with a reliable empty-metadata fallback.
  String get authorLine =>
      authors.isEmpty ? 'Unknown author' : authors.join(', ');

  /// Whether the user has opened or advanced into this publication.
  bool get started => lastLocator != null || progress > 0;

  /// Treats the final half-percent as complete to absorb locator rounding.
  bool get finished => progress >= 0.995;

  /// Returns a new record with mutable reading-state fields replaced.
  CatalogBook copyWith({
    String? coverPath,
    Map<String, dynamic>? lastLocator,
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
    lastLocator: lastLocator ?? this.lastLocator,
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
    if (lastLocator != null) 'lastLocator': lastLocator,
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
    lastLocator: (json['lastLocator'] as Map?)?.cast<String, dynamic>(),
    progress: ((json['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1),
    addedAt: DateTime.parse(json['addedAt'] as String),
    lastOpenedAt: json['lastOpenedAt'] == null
        ? null
        : DateTime.parse(json['lastOpenedAt'] as String),
  );
}

/// Outcome categories reported independently for each selected file.
enum ImportStatus {
  /// The EPUB was validated and committed.
  imported,

  /// An identical SHA-256 hash already exists in the catalog.
  duplicate,

  /// Validation, parsing, or storage failed.
  failed,
}

/// User-facing result of one EPUB import attempt.
class ImportResult {
  /// Creates an outcome for one selected filename.
  const ImportResult(this.fileName, this.status, {this.message});

  /// Original selected filename.
  final String fileName;

  /// Result category.
  final ImportStatus status;

  /// Optional validation or platform error suitable for display.
  final String? message;
}
