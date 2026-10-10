/// Normalization version; positions are valid only for this document format.
const textDocumentVersion = 1;

/// Layout-independent leading reading position, never a page or pixel index.
class TextPosition {
  /// Offsets use UTF-16, matching Flutter, and must be grapheme boundaries.
  const TextPosition({
    required this.sectionId,
    required this.blockId,
    this.offset = 0,
    this.version = textDocumentVersion,
  });

  /// Normalization version used to reject incompatible saved positions.
  final int version;

  /// Stable normalized section identifier.
  final String sectionId;

  /// Stable normalized block identifier.
  final String blockId;

  /// UTF-16 offset within the block, clamped before layout or persistence.
  final int offset;

  /// Durable position representation.
  Map<String, dynamic> toJson() => {
    'version': version,
    'sectionId': sectionId,
    'blockId': blockId,
    'offset': offset,
  };

  /// Restores a position; validation against its document happens on opening.
  factory TextPosition.fromJson(Map<String, dynamic> json) => TextPosition(
    version: json['version'] as int,
    sectionId: json['sectionId'] as String,
    blockId: json['blockId'] as String,
    offset: json['offset'] as int,
  );
  @override
  bool operator ==(Object other) =>
      other is TextPosition &&
      version == other.version &&
      sectionId == other.sectionId &&
      blockId == other.blockId &&
      offset == other.offset;
  @override
  int get hashCode => Object.hash(version, sectionId, blockId, offset);
  @override
  String toString() => 'TextPosition(v$version, $sectionId/$blockId@$offset)';
}
