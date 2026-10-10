/// Small section metadata retained while section text stays on disk.
class SectionSummary {
  /// Stores source mapping and progress without keeping prose in memory.
  const SectionSummary({
    required this.id,
    required this.title,
    required this.source,
    required this.length,
    this.language,
  });

  /// Generated section resource identifier.
  final String id;

  /// Display title from EPUB metadata or deterministic TXT section numbering.
  final String title;

  /// Original archive resource path, or TXT section identifier.
  final String source;

  /// Number of normalized UTF-16 units in this section.
  final int length;

  /// Source language hint, if present.
  final String? language;

  /// Serializable summary used by document.json.
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'source': source,
    'length': length,
    if (language != null) 'language': language,
  };

  /// Restores a summary without loading its prose.
  factory SectionSummary.fromJson(Map<String, dynamic> json) => SectionSummary(
    id: json['id'] as String,
    title: json['title'] as String,
    source: json['source'] as String,
    length: json['length'] as int,
    language: json['language'] as String?,
  );
}
