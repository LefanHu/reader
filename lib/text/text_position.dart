/// Layout-independent leading reading position, never a page or pixel index.
class TextPosition {
  /// Offsets use UTF-16, matching Flutter, and must be grapheme boundaries.
  const TextPosition({
    required this.sectionId,
    required this.blockId,
    this.offset = 0,
  });

  /// Stable normalized section identifier.
  final String sectionId;

  /// Stable normalized block identifier.
  final String blockId;

  /// UTF-16 offset within the block, clamped before layout or persistence.
  final int offset;

  /// Durable position representation.
  Map<String, dynamic> toJson() => {
    'sectionId': sectionId,
    'blockId': blockId,
    'offset': offset,
  };

  /// Restores a position; validation against its document happens on opening.
  factory TextPosition.fromJson(Map<String, dynamic> json) => TextPosition(
    sectionId: json['sectionId'] as String,
    blockId: json['blockId'] as String,
    offset: json['offset'] as int,
  );
  @override
  bool operator ==(Object other) =>
      other is TextPosition &&
      sectionId == other.sectionId &&
      blockId == other.blockId &&
      offset == other.offset;
  @override
  int get hashCode => Object.hash(sectionId, blockId, offset);
  @override
  String toString() => 'TextPosition($sectionId/$blockId@$offset)';
}
