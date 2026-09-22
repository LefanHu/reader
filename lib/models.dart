enum ReadingMode { scroll, pages }

enum ReadingTheme { paper, sepia, dark }

enum LibraryFilter { all, reading, finished }

enum LibrarySort { recent, title }

class ReaderSettings {
  const ReaderSettings({
    this.mode = ReadingMode.scroll,
    this.theme = ReadingTheme.paper,
    this.fontSize = 100,
    this.serif = true,
  });

  final ReadingMode mode;
  final ReadingTheme theme;
  final int fontSize;
  final bool serif;

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

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'theme': theme.name,
    'fontSize': fontSize,
    'serif': serif,
  };

  factory ReaderSettings.fromJson(Map<String, dynamic> json) => ReaderSettings(
    mode: ReadingMode.values.byName(json['mode'] as String? ?? 'scroll'),
    theme: ReadingTheme.values.byName(json['theme'] as String? ?? 'paper'),
    fontSize: (json['fontSize'] as num?)?.round().clamp(80, 180) ?? 100,
    serif: json['serif'] as bool? ?? true,
  );
}

class CatalogBook {
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

  final String hash;
  final String fileName;
  final String path;
  final String title;
  final List<String> authors;
  final String? identifier;
  final String? language;
  final String? coverPath;
  final Map<String, dynamic>? lastLocator;
  final double progress;
  final DateTime addedAt;
  final DateTime? lastOpenedAt;

  String get authorLine =>
      authors.isEmpty ? 'Unknown author' : authors.join(', ');
  bool get started => lastLocator != null || progress > 0;
  bool get finished => progress >= 0.995;

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

enum ImportStatus { imported, duplicate, failed }

class ImportResult {
  const ImportResult(this.fileName, this.status, {this.message});
  final String fileName;
  final ImportStatus status;
  final String? message;
}
