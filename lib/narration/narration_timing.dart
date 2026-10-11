import 'narration_cue.dart';

/// Versioned optional presentation metadata, never a prerequisite for audio.
/// Owners must also verify identities, clip/grapheme bounds and decoded duration.
class NarrationTiming {
  /// Owns, sorts and deduplicates cues, rejecting empty identities, invalid
  /// durations, out-of-duration cue starts and mixed source blocks/versions.
  /// Does not establish whether native offsets were experimentally verified.
  NarrationTiming({
    required this.audioKey,
    required this.chunkId,
    required this.sourceDigest,
    required this.synthesisFingerprint,
    required this.duration,
    required List<NarrationCue> cues,
  }) : cues = _validated(cues, duration) {
    if ([
      audioKey,
      chunkId,
      sourceDigest,
      synthesisFingerprint,
    ].any((identity) => identity.isEmpty)) {
      throw const FormatException('Missing narration timing identity.');
    }
  }

  /// Exact device-local or account-isolated cache key of the companion WAV.
  final String audioKey;

  /// Complete-anchor identity of the exact audio clip, not the sentence.
  final String chunkId;

  /// Digest of the exact normalized source substring synthesized for the clip.
  final String sourceDigest;

  /// OS/provider synthesis identity; changed synthesis invalidates cached cues.
  final String synthesisFingerprint;

  /// Source-media duration persisted as integer `durationUs`, without speed.
  final Duration duration;

  /// Immutable native start markers persisted with complete source positions.
  final List<NarrationCue> cues;

  static List<NarrationCue> _validated(
    List<NarrationCue> source,
    Duration duration,
  ) {
    if (duration <= Duration.zero) {
      throw const FormatException('Invalid narration timing duration.');
    }
    final sorted = List<NarrationCue>.of(source);
    for (final cue in sorted) {
      if (cue.time < Duration.zero || cue.time > duration) {
        throw const FormatException('Narration cue lies outside audio.');
      }
      if (sorted.isNotEmpty) {
        final first = sorted.first.range.start;
        final start = cue.range.start;
        if (first.version != start.version ||
            first.sectionId != start.sectionId ||
            first.blockId != start.blockId) {
          throw const FormatException(
            'Narration cues cross source identities.',
          );
        }
      }
    }
    sorted.sort((a, b) {
      final time = a.time.compareTo(b.time);
      if (time != 0) return time;
      final kind = a.kind.index.compareTo(b.kind.index);
      if (kind != 0) return kind;
      final start = a.range.start.offset.compareTo(b.range.start.offset);
      return start != 0
          ? start
          : a.range.end.offset.compareTo(b.range.end.offset);
    });
    final unique = <NarrationCue>[];
    for (final cue in sorted) {
      if (unique.isEmpty ||
          unique.last.time != cue.time ||
          unique.last.kind != cue.kind ||
          unique.last.range != cue.range) {
        unique.add(cue);
      }
    }
    return List.unmodifiable(unique);
  }

  /// Native words take precedence as a timeline; otherwise native sentences.
  late final List<NarrationCue> preferredCues = _preferred(cues);

  static List<NarrationCue> _preferred(List<NarrationCue> cues) {
    final kind = cues.any((cue) => cue.kind == NarrationCueKind.word)
        ? NarrationCueKind.word
        : NarrationCueKind.sentence;
    return List.unmodifiable(cues.where((cue) => cue.kind == kind));
  }

  /// Duration comparisons use the one-millisecond player/WAV rounding tolerance.
  bool matches({
    String? audioKey,
    String? chunkId,
    String? sourceDigest,
    String? synthesisFingerprint,
    Duration? duration,
  }) =>
      (audioKey == null || this.audioKey == audioKey) &&
      (chunkId == null || this.chunkId == chunkId) &&
      (sourceDigest == null || this.sourceDigest == sourceDigest) &&
      (synthesisFingerprint == null ||
          this.synthesisFingerprint == synthesisFingerprint) &&
      (duration == null ||
          (this.duration - duration).inMicroseconds.abs() <= 1000);

  /// Version-1 companion schema with integer source-media microseconds.
  Map<String, dynamic> toJson() => {
    'version': 1,
    'audioKey': audioKey,
    'chunkId': chunkId,
    'sourceDigest': sourceDigest,
    'synthesisFingerprint': synthesisFingerprint,
    'durationUs': duration.inMicroseconds,
    'cues': cues.map((cue) => cue.toJson()).toList(),
  };

  /// Malformed metadata is rejected independently of the associated WAV.
  factory NarrationTiming.fromJson(Map<String, dynamic> json) {
    try {
      if (json['version'] != 1 || json['durationUs'] is! int) {
        throw const FormatException('Unsupported narration timing metadata.');
      }
      return NarrationTiming(
        audioKey: json['audioKey'] as String,
        chunkId: json['chunkId'] as String,
        sourceDigest: json['sourceDigest'] as String,
        synthesisFingerprint: json['synthesisFingerprint'] as String,
        duration: Duration(microseconds: json['durationUs'] as int),
        cues: (json['cues'] as List)
            .map(
              (cue) =>
                  NarrationCue.fromJson((cue as Map).cast<String, dynamic>()),
            )
            .toList(),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Malformed narration timing metadata.');
    }
  }

  /// Cache corruption means sentence fallback, not regeneration or audio failure.
  static NarrationTiming? tryFromJson(Object? json) {
    try {
      return NarrationTiming.fromJson((json as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }
}
