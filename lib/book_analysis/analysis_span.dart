import '../text/text_position.dart';

/// Analysis anchors use the existing complete persisted reading-position shape.
typedef AnalysisPosition = TextPosition;

/// Nonempty, block-local, end-exclusive evidence. Never resolved or snapped.
class AnalysisSpan {
  /// Rejects malformed anchors; source grapheme validation is a separate step.
  AnalysisSpan({required this.start, required this.end}) {
    if (start.version != end.version ||
        start.sectionId != end.sectionId ||
        start.blockId != end.blockId ||
        start.offset < 0 ||
        end.offset <= start.offset) {
      throw const FormatException('Invalid analysis evidence span.');
    }
  }

  /// First included UTF-16 position.
  final AnalysisPosition start;

  /// First excluded UTF-16 position in the same normalized block.
  final AnalysisPosition end;

  /// Position-only evidence; raw source quotations are not persisted.
  Map<String, dynamic> toJson() => {
    'start': start.toJson(),
    'end': end.toJson(),
  };

  /// Restores exact offsets, rejecting empty and cross-block evidence.
  factory AnalysisSpan.fromJson(Map<String, dynamic> json) => AnalysisSpan(
    start: TextPosition.fromJson(
      (json['start'] as Map).cast<String, dynamic>(),
    ),
    end: TextPosition.fromJson((json['end'] as Map).cast<String, dynamic>()),
  );
}
