import 'text_position.dart';

/// A nonempty, exclusive source range within one normalized block/version.
/// Offsets must additionally be checked against the source's grapheme boundaries.
class NarrationRange {
  /// Rejects empty, reversed or mixed-identity ranges before presentation.
  NarrationRange(this.start, this.end) {
    if (start.version != end.version ||
        start.sectionId != end.sectionId ||
        start.blockId != end.blockId ||
        start.sectionId.isEmpty ||
        start.blockId.isEmpty ||
        start.offset < 0 ||
        end.offset <= start.offset) {
      throw const FormatException('Invalid narration source range.');
    }
  }

  /// Complete leading source anchor, inclusive.
  final TextPosition start;

  /// Complete ending source anchor, exclusive.
  final TextPosition end;

  /// Whether another full-identity range lies wholly within this range.
  bool contains(NarrationRange other) =>
      start.version == other.start.version &&
      start.sectionId == other.start.sectionId &&
      start.blockId == other.start.blockId &&
      start.offset <= other.start.offset &&
      end.offset >= other.end.offset;

  /// Complete anchors used by version-1 timing cue JSON.
  Map<String, dynamic> toJson() => {
    'start': start.toJson(),
    'end': end.toJson(),
  };

  /// Restores complete anchors and validates their shared range identity.
  factory NarrationRange.fromJson(Map<String, dynamic> json) => NarrationRange(
    TextPosition.fromJson((json['start'] as Map).cast<String, dynamic>()),
    TextPosition.fromJson((json['end'] as Map).cast<String, dynamic>()),
  );

  @override
  bool operator ==(Object other) =>
      other is NarrationRange && start == other.start && end == other.end;
  @override
  int get hashCode => Object.hash(start, end);
}
