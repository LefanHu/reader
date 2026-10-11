import '../text/narration_range.dart';

/// Only native spoken-text markers participate in presentation.
enum NarrationCueKind {
  /// Native spoken-word start marker.
  word,

  /// Native spoken-sentence start marker.
  sentence,
}

/// A source-media start marker. It does not establish a spoken word's end time.
class NarrationCue {
  /// Binds a native marker to normalized source; timing validates media bounds.
  const NarrationCue({
    required this.time,
    required this.range,
    required this.kind,
  });

  /// Source-media offset serialized as integer `timeUs`, never wall-clock time.
  final Duration time;

  /// Complete grapheme-safe source bounds, serialized as `start` and `end`.
  final NarrationRange range;

  /// Native text marker category, serialized as `word` or `sentence`.
  final NarrationCueKind kind;

  /// Version-1 timing companion cue representation.
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'timeUs': time.inMicroseconds,
    ...range.toJson(),
  };

  /// Reads a cue; the containing timing parser rejects corrupt source anchors.
  factory NarrationCue.fromJson(Map<String, dynamic> json) {
    final kind = switch (json['kind']) {
      'word' => NarrationCueKind.word,
      'sentence' => NarrationCueKind.sentence,
      _ => throw const FormatException('Invalid narration cue kind.'),
    };
    if (json['timeUs'] is! int || (json['timeUs'] as int) < 0) {
      throw const FormatException('Invalid narration cue time.');
    }
    return NarrationCue(
      time: Duration(microseconds: json['timeUs'] as int),
      range: NarrationRange.fromJson(json),
      kind: kind,
    );
  }
}
