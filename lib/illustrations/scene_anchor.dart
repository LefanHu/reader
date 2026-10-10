// Persisted field meanings and lifecycle invariants are documented per model.
// ignore_for_file: public_member_api_docs

/// Conservative release point at the end of a scene's source passage.
class SceneAnchor {
  const SceneAnchor({
    required this.href,
    required this.spineOrdinal,
    required this.paragraphId,
    required this.cssSelector,
    required this.fallbackProgression,
  });

  /// Normalized section ID used as the backend resource identifier.
  final String href;
  final int spineOrdinal;
  final String paragraphId;

  /// Deterministic block selector retained for backend wire compatibility.
  /// Unlocking uses paragraph identity, never DOM visibility.
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
