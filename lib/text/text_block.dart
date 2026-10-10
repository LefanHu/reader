/// Normalized paragraph or heading shared verbatim with illustration jobs.
class TextBlock {
  /// Source fragments retain navigation targets after publisher markup is lost.
  const TextBlock({
    required this.id,
    required this.text,
    this.kind = 'paragraph',
    this.direction,
    this.sourceId,
  });

  /// Stable content-addressed block identifier.
  final String id;

  /// Unicode text; explicit line breaks are retained.
  final String text;

  /// Structural style: paragraph, heading, list, quote, or pre.
  final String kind;

  /// Explicit inherited source direction, otherwise first-strong detection.
  final String? direction;

  /// Original HTML ID used by nested EPUB navigation.
  final String? sourceId;

  /// Serializable normalized block.
  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'kind': kind,
    if (direction != null) 'direction': direction,
    if (sourceId != null) 'sourceId': sourceId,
  };

  /// Restores a block from a section sidecar.
  factory TextBlock.fromJson(Map<String, dynamic> json) => TextBlock(
    id: json['id'] as String,
    text: json['text'] as String,
    kind: json['kind'] as String,
    direction: json['direction'] as String?,
    sourceId: json['sourceId'] as String?,
  );
}
