/// Stable normalized block shared verbatim with the reading viewport.
class IndexedParagraph {
  /// [progression] is derived from [ordinal] within the section.
  const IndexedParagraph({
    required this.id,
    required this.text,
    required this.ordinal,
    required this.progression,
  });

  /// Stable block ID; scene anchors name it.
  final String id;

  /// Exact normalized block text.
  final String text;

  /// Zero-based block order in the normalized section.
  final int ordinal;

  /// Section progress at the paragraph's release boundary.
  final double progression;
}
