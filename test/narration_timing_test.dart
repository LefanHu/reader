import 'package:flutter_test/flutter_test.dart';
import 'package:reader/narration/narration_cue.dart';
import 'package:reader/narration/narration_timing.dart';
import 'package:reader/text/narration_range.dart';
import 'package:reader/text/text_position.dart';

NarrationRange range(int start, int end, {String block = 'p'}) =>
    NarrationRange(
      TextPosition(sectionId: 's', blockId: block, offset: start),
      TextPosition(sectionId: 's', blockId: block, offset: end),
    );
NarrationCue cue(
  int ms,
  int start,
  int end, {
  NarrationCueKind kind = NarrationCueKind.word,
}) => NarrationCue(
  time: Duration(milliseconds: ms),
  range: range(start, end),
  kind: kind,
);
NarrationTiming timing(List<NarrationCue> cues) => NarrationTiming(
  audioKey: 'key',
  chunkId: 'chunk',
  sourceDigest: 'digest',
  synthesisFingerprint: 'os',
  duration: const Duration(seconds: 1),
  cues: cues,
);

void main() {
  test('timing owns sorted immutable deduplicated cues and round trips full anchors', () {
    final source = [cue(600, 6, 11), cue(100, 0, 5), cue(100, 0, 5)];
    final value = timing(source);
    source.clear();
    expect(value.cues.map((c) => c.time.inMilliseconds), [100, 600]);
    expect(() => value.cues.clear(), throwsUnsupportedError);
    final decoded = NarrationTiming.fromJson(value.toJson());
    expect(decoded.toJson(), value.toJson());
    expect(decoded.cues.first.range.start.version, textDocumentVersion);
    expect(decoded.cues.first.range.start.sectionId, 's');
    expect(decoded.cues.first.range.start.blockId, 'p');
    expect(
      value.matches(
        audioKey: 'key',
        chunkId: 'chunk',
        sourceDigest: 'digest',
        synthesisFingerprint: 'os',
        duration: const Duration(microseconds: 1001000),
      ),
      isTrue,
    );
    expect(
      value.matches(duration: const Duration(microseconds: 1001001)),
      isFalse,
    );
    expect(value.matches(sourceDigest: 'changed'), isFalse);
  });

  test('native word timeline takes precedence, otherwise sentence timeline survives', () {
    final sentence = cue(0, 0, 11, kind: NarrationCueKind.sentence);
    final words = timing([sentence, cue(100, 0, 5), cue(600, 6, 11)]);
    expect(words.preferredCues.map((c) => c.kind), [
      NarrationCueKind.word,
      NarrationCueKind.word,
    ]);
    expect(timing([sentence]).preferredCues.single.range, range(0, 11));
    expect(timing([]).preferredCues, isEmpty);
  });

  test(
    'corrupt optional metadata is unusable, never repaired into plausible cues',
    () {
      final valid = timing([cue(100, 0, 5)]).toJson();
      for (final changes in <Map<String, dynamic>>[
        {'version': 2},
        {'durationUs': 0},
        {'durationUs': 1.5},
        {'audioKey': ''},
        {'chunkId': null},
        {'sourceDigest': []},
        {'synthesisFingerprint': ''},
        {'cues': null},
        {
          'cues': [
            {'kind': 'paragraph', 'timeUs': 10, ...range(0, 5).toJson()},
          ],
        },
        {
          'cues': [
            {'kind': 'word', 'timeUs': -1, ...range(0, 5).toJson()},
          ],
        },
        {
          'cues': [
            {'kind': 'word', 'timeUs': 1000001, ...range(0, 5).toJson()},
          ],
        },
        {
          'cues': [
            {'kind': 'word', 'timeUs': 1, 'start': {}, 'end': {}},
          ],
        },
      ]) {
        final corrupt = {...valid, ...changes};
        expect(NarrationTiming.tryFromJson(corrupt), isNull);
        expect(() => NarrationTiming.fromJson(corrupt), throwsFormatException);
      }
      expect(NarrationTiming.tryFromJson('not json'), isNull);
      expect(() => timing([cue(-1, 0, 5)]), throwsFormatException);
      expect(() => timing([cue(1001, 0, 5)]), throwsFormatException);
      expect(
        () => timing([
          cue(0, 0, 5),
          NarrationCue(
            time: Duration.zero,
            range: range(0, 5, block: 'other'),
            kind: NarrationCueKind.word,
          ),
        ]),
        throwsFormatException,
      );
    },
  );

  test('ranges reject incomplete, empty or crossing block identities', () {
    expect(() => range(2, 2), throwsFormatException);
    expect(() => range(-1, 2), throwsFormatException);
    expect(
      () => NarrationRange(
        const TextPosition(sectionId: 's', blockId: 'p'),
        const TextPosition(sectionId: 's', blockId: 'other', offset: 2),
      ),
      throwsFormatException,
    );
    expect(range(0, 11).contains(range(6, 11)), isTrue);
    expect(range(0, 11).contains(range(6, 11, block: 'other')), isFalse);
  });
}
