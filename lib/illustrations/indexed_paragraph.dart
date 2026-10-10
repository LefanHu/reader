// Persisted field meanings and lifecycle invariants are documented per model.
// ignore_for_file: public_member_api_docs

/// Stable normalized block shared verbatim with the reading viewport.
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

  /// Deterministic block selector retained for backend wire compatibility.
  /// Unlocking uses paragraph identity, never DOM visibility.
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
