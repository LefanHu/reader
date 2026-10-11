import 'package:flutter_test/flutter_test.dart';
import 'package:reader/narration/narration_cue.dart';
import 'package:reader/narration/narration_highlight_tracker.dart';
import 'package:reader/narration/narration_playback_clock.dart';
import 'package:reader/narration/narration_timing.dart';
import 'package:reader/text/narration_chunk.dart';
import 'package:reader/text/narration_playback_unit.dart';
import 'package:reader/text/narration_range.dart';
import 'package:reader/text/text_position.dart';

import 'support/fake_narration_player.dart';

void main() {
  _trackerTest(
    'Hello/world starts use actual media time, never source progress',
    (tester, fixture) async {
      fixture.tracker.attach(fixture.owner);
      final start = fixture.unit.chunk.start;
      final end = fixture.unit.chunk.end;
      await fixture.start(tester, offset: const Duration(milliseconds: 50));
      expect(fixture.tracker.range, isNull);
      expect(fixture.tracker.hasNativeTiming, isTrue);
      expect(fixture.changes, isEmpty);

      fixture.player.position = const Duration(milliseconds: 200);
      await tester.pump(const Duration(milliseconds: 50));
      expect(fixture.tracker.range, _range(0, 5));
      await fixture.player.seekAudio(const Duration(milliseconds: 650));
      await tester.pump();
      expect(fixture.tracker.range, _range(7, 12));
      expect(fixture.changes, [_range(0, 5), _range(7, 12)]);
      expect(fixture.unit.chunk.start, start);
      expect(fixture.unit.chunk.end, end);
    },
  );

  _trackerTest('one boundary timer keeps each start range until the next cue', (
    tester,
    fixture,
  ) async {
    fixture.tracker.attach(fixture.owner);
    await fixture.start(tester, offset: const Duration(milliseconds: 100));
    expect(fixture.tracker.range, _range(0, 5));

    fixture.player.position = const Duration(milliseconds: 600);
    await tester.pump(const Duration(milliseconds: 499));
    expect(fixture.tracker.range, _range(0, 5));
    await tester.pump(const Duration(milliseconds: 1));
    expect(fixture.tracker.range, _range(7, 12));
    fixture.player.position = const Duration(milliseconds: 950);
    fixture.player.emitClock();
    await tester.pump();
    expect(fixture.tracker.range, _range(7, 12));
    expect(fixture.changes.length, 2);
    fixture.player.finish();
    await tester.pump();
    expect(fixture.tracker.range, isNull);
  });

  _trackerTest(
    'queued positions cannot override actual position or duplicate changes',
    (tester, fixture) async {
      fixture.tracker.attach(fixture.owner);
      await fixture.start(tester, offset: const Duration(milliseconds: 50));
      fixture.player.clocks.add(
        NarrationPlaybackClock(
          token: fixture.player.token!,
          position: const Duration(milliseconds: 650),
          speed: 1,
          advancing: true,
        ),
      );
      await tester.pump();
      expect(fixture.tracker.range, isNull);

      fixture.player.position = const Duration(milliseconds: 200);
      fixture.player.clocks.add(
        NarrationPlaybackClock(
          token: fixture.player.token!,
          position: const Duration(milliseconds: 50),
          speed: 1,
          advancing: true,
        ),
      );
      await tester.pump();
      fixture.player.emitClock();
      fixture.player.emitClock();
      await tester.pump();
      expect(fixture.tracker.range, _range(0, 5));
      expect(fixture.changes, [_range(0, 5)]);
    },
  );

  _trackerTest('speed and seek reschedule boundaries in source-media time', (
    tester,
    fixture,
  ) async {
    fixture.tracker.attach(fixture.owner);
    await fixture.start(tester, offset: const Duration(milliseconds: 200));
    await fixture.player.speed(2);
    await tester.pump();
    fixture.player.position = const Duration(milliseconds: 600);
    await tester.pump(const Duration(milliseconds: 199));
    expect(fixture.tracker.range, _range(0, 5));
    await tester.pump(const Duration(milliseconds: 1));
    expect(fixture.tracker.range, _range(7, 12));

    await fixture.player.seekAudio(const Duration(milliseconds: 50));
    await tester.pump();
    expect(fixture.tracker.range, isNull);
    fixture.player.position = const Duration(milliseconds: 100);
    await tester.pump(const Duration(milliseconds: 24));
    expect(fixture.tracker.range, isNull);
    await tester.pump(const Duration(milliseconds: 1));
    expect(fixture.tracker.range, _range(0, 5));
  });

  _trackerTest(
    'pause and stalls clear ranges; fresh resume snapshots restore them',
    (tester, fixture) async {
      fixture.tracker.attach(fixture.owner);
      await fixture.start(tester, offset: const Duration(milliseconds: 200));
      await fixture.player.pauseAudio();
      await tester.pump();
      expect(fixture.tracker.range, isNull);
      expect(fixture.tracker.hasNativeTiming, isTrue);
      final pausedChanges = fixture.changes.length;
      fixture.player.position = const Duration(milliseconds: 650);
      await tester.pump(const Duration(seconds: 2));
      expect(fixture.changes.length, pausedChanges);
      await fixture.player.pauseAudio();
      await tester.pump();
      expect(fixture.changes.length, pausedChanges);

      await fixture.player.resume();
      await tester.pump();
      expect(fixture.tracker.range, _range(7, 12));
      fixture.player.position = const Duration(milliseconds: 200);
      await fixture.player.resume();
      await tester.pump();
      expect(fixture.tracker.range, _range(0, 5));
      fixture.player.ready = false;
      fixture.player.emitClock();
      await tester.pump();
      expect(fixture.tracker.range, isNull);
      final stalledChanges = fixture.changes.length;
      fixture.player.position = const Duration(milliseconds: 650);
      await tester.pump(const Duration(seconds: 2));
      expect(fixture.changes.length, stalledChanges);
      fixture.player.ready = true;
      fixture.player.emitClock();
      await tester.pump();
      expect(fixture.tracker.range, _range(7, 12));
    },
  );

  _trackerTest(
    'only the identical mounted owner can detach boundary scheduling',
    (tester, fixture) async {
      await fixture.start(tester, offset: const Duration(milliseconds: 200));
      fixture.player.position = const Duration(milliseconds: 650);
      await tester.pump(const Duration(seconds: 2));
      expect(fixture.changes, isEmpty);
      fixture.tracker.attach(fixture.owner);
      expect(fixture.tracker.range, _range(7, 12));

      final replacement = Object();
      fixture.player.position = const Duration(milliseconds: 200);
      fixture.tracker.attach(replacement);
      expect(fixture.tracker.range, _range(0, 5));
      fixture.tracker.detach(fixture.owner);
      expect(fixture.tracker.range, _range(0, 5));
      fixture.tracker.detach(replacement);
      expect(fixture.tracker.range, isNull);
      final detachedChanges = fixture.changes.length;
      fixture.player.position = const Duration(milliseconds: 650);
      await tester.pump(const Duration(seconds: 2));
      expect(fixture.changes.length, detachedChanges);
      fixture.tracker.attach(replacement);
      expect(fixture.tracker.range, _range(7, 12));
    },
  );

  _trackerTest(
    'early ready clocks survive clear/load and reject stale tokens',
    (tester, fixture) async {
      fixture.tracker.attach(fixture.owner);
      await fixture.player.load(
        'first.wav',
        'Book',
        1,
        const Duration(milliseconds: 50),
      );
      await fixture.player.resume();
      await tester.pump();
      expect(fixture.tracker.range, isNull);
      fixture.player.position = const Duration(milliseconds: 200);
      fixture.tracker.load(
        token: 1,
        unit: fixture.unit,
        timing: fixture.timing,
      );
      expect(fixture.tracker.range, _range(0, 5));
      fixture.tracker.clear();
      expect(fixture.tracker.range, isNull);
      expect(fixture.tracker.hasNativeTiming, isFalse);

      // Source replacement is already playing; there need not be a new state value.
      await fixture.player.load(
        'second.wav',
        'Book',
        2,
        const Duration(milliseconds: 650),
      );
      await tester.pump();
      fixture.player.clocks.add(
        const NarrationPlaybackClock(
          token: 1,
          position: Duration.zero,
          speed: 1,
          advancing: false,
        ),
      );
      await tester.pump();
      fixture.tracker.load(
        token: 2,
        unit: fixture.unit,
        timing: fixture.timing,
      );
      expect(fixture.tracker.range, _range(7, 12));
      fixture.player.finish(1);
      await tester.pump();
      expect(fixture.tracker.range, _range(7, 12));
      fixture.tracker.load(
        token: 1,
        unit: fixture.unit,
        timing: fixture.timing,
      );
      expect(fixture.tracker.range, _range(7, 12));
      fixture.player.finish();
      await tester.pump();
      expect(fixture.tracker.range, isNull);
      fixture.tracker.attach(fixture.owner);
      expect(fixture.tracker.range, isNull);
    },
  );

  _trackerTest(
    'usable words outrank native sentences even before their first cue',
    (tester, fixture) async {
      fixture.tracker.attach(fixture.owner);
      final timing = _timing(
        fixture.unit,
        cues: [
          NarrationCue(
            time: const Duration(milliseconds: 25),
            range: _range(0, 6),
            kind: NarrationCueKind.sentence,
          ),
          ...fixture.timing.cues,
        ],
      );
      await fixture.start(
        tester,
        offset: const Duration(milliseconds: 50),
        timing: timing,
      );
      expect(fixture.tracker.range, isNull);
      await fixture.player.seekAudio(const Duration(milliseconds: 200));
      await tester.pump();
      expect(fixture.tracker.range, _range(0, 5));
    },
  );

  _trackerTest(
    'native sentence bounds outrank the enclosing declared fallback',
    (tester, fixture) async {
      fixture.tracker.attach(fixture.owner);
      await fixture.start(
        tester,
        offset: const Duration(milliseconds: 200),
        timing: _timing(
          fixture.unit,
          cues: [
            NarrationCue(
              time: const Duration(milliseconds: 100),
              range: _range(0, 6),
              kind: NarrationCueKind.sentence,
            ),
            NarrationCue(
              time: const Duration(milliseconds: 600),
              range: _range(7, 13),
              kind: NarrationCueKind.sentence,
            ),
          ],
        ),
      );
      expect(fixture.tracker.range, _range(0, 6));
      await fixture.player.seekAudio(const Duration(milliseconds: 650));
      await tester.pump();
      expect(fixture.tracker.range, _range(7, 13));
    },
  );

  _trackerTest('unusable words do not hide usable native sentence cues', (
    tester,
    fixture,
  ) async {
    fixture.tracker.attach(fixture.owner);
    await fixture.start(
      tester,
      timing: _timing(
        fixture.unit,
        cues: [
          NarrationCue(
            time: const Duration(milliseconds: 100),
            range: _range(0, 14),
            kind: NarrationCueKind.word,
          ),
          NarrationCue(
            time: const Duration(milliseconds: 100),
            range: _range(0, 6),
            kind: NarrationCueKind.sentence,
          ),
        ],
      ),
    );
    expect(fixture.tracker.range, _range(0, 6));
  });

  _trackerTest(
    'absent and incompatible metadata use the sentence, without regeneration',
    (tester, fixture) async {
      fixture.tracker.attach(fixture.owner);
      await fixture.start(
        tester,
        offset: const Duration(milliseconds: 50),
        markerless: true,
      );
      expect(fixture.tracker.range, fixture.unit.sentence);
      expect(fixture.tracker.hasNativeTiming, isFalse);

      for (final timing in [
        _timing(fixture.unit, sourceDigest: 'different-source'),
        _timing(fixture.unit, chunkId: 'different-clip'),
        _timing(fixture.unit, duration: const Duration(milliseconds: 1002)),
        _timing(
          fixture.unit,
          cues: [
            NarrationCue(
              time: const Duration(milliseconds: 100),
              range: _range(0, 14),
              kind: NarrationCueKind.word,
            ),
          ],
        ),
        _timing(
          fixture.unit,
          cues: [
            NarrationCue(
              time: const Duration(milliseconds: 100),
              range: NarrationRange(
                const TextPosition(sectionId: 'other', blockId: 'p0'),
                const TextPosition(
                  sectionId: 'other',
                  blockId: 'p0',
                  offset: 5,
                ),
              ),
              kind: NarrationCueKind.word,
            ),
          ],
        ),
        _timing(fixture.unit, cues: []),
      ]) {
        await fixture.start(tester, timing: timing);
        expect(fixture.tracker.range, fixture.unit.sentence);
      }
      fixture.player.length = null;
      fixture.tracker.load(
        token: fixture.player.token!,
        unit: fixture.unit,
        timing: fixture.timing,
      );
      expect(fixture.tracker.range, fixture.unit.sentence);
      expect(
        fixture.changes.whereType<NarrationRange>(),
        everyElement(fixture.unit.sentence),
      );
    },
  );

  _trackerTest(
    'clip-relative grapheme bounds reject a split combining sequence',
    (tester, fixture) async {
      final unit = fixture.unit;
      fixture.tracker.attach(fixture.owner);
      await fixture.start(
        tester,
        offset: const Duration(milliseconds: 200),
        timing: _timing(
          unit,
          cues: [
            NarrationCue(
              time: const Duration(milliseconds: 100),
              range: _range(12, 13),
              kind: NarrationCueKind.word,
            ),
          ],
        ),
      );
      expect(fixture.tracker.range, unit.sentence);
      await fixture.start(
        tester,
        offset: const Duration(milliseconds: 200),
        timing: _timing(
          unit,
          cues: [
            NarrationCue(
              time: const Duration(milliseconds: 100),
              range: _range(12, 14),
              kind: NarrationCueKind.word,
            ),
          ],
        ),
      );
      expect(fixture.tracker.range, _range(12, 14));
    },
    unit: _unit('e\u0301 test.', startOffset: 12),
  );

  _trackerTest(
    'detaching inside a change callback cannot leave a timer running',
    (tester, fixture) async {
      fixture.tracker.attach(fixture.owner);
      fixture.onChange = () {
        if (fixture.tracker.range != null) {
          fixture.tracker.detach(fixture.owner);
        }
      };
      await fixture.start(tester, offset: const Duration(milliseconds: 200));
      expect(fixture.tracker.range, isNull);
      final changes = fixture.changes.length;
      fixture.player.position = const Duration(milliseconds: 650);
      await tester.pump(const Duration(seconds: 2));
      expect(fixture.tracker.range, isNull);
      expect(fixture.changes.length, changes);
    },
  );
}

void _trackerTest(
  String description,
  Future<void> Function(WidgetTester tester, _Fixture fixture) body, {
  NarrationPlaybackUnit? unit,
}) {
  testWidgets(description, (tester) async {
    final fixture = _Fixture(unit: unit);
    try {
      await body(tester, fixture);
    } finally {
      // Flutter checks pending timers before addTearDown runs.
      await fixture.dispose(tester);
    }
  });
}

TextPosition _position(int offset) =>
    TextPosition(sectionId: 's0', blockId: 'p0', offset: offset);

NarrationRange _range(int start, int end) =>
    NarrationRange(_position(start), _position(end));

NarrationPlaybackUnit _unit(String text, {int startOffset = 0}) =>
    NarrationPlaybackUnit(
      chunk: NarrationChunk(
        text: text,
        start: _position(startOffset),
        end: _position(startOffset + text.length),
      ),
      sentence: _range(startOffset, startOffset + text.length),
    );

NarrationTiming _timing(
  NarrationPlaybackUnit unit, {
  List<NarrationCue>? cues,
  String? sourceDigest,
  String? chunkId,
  Duration duration = const Duration(seconds: 1),
}) => NarrationTiming(
  audioKey: 'fixture-audio-key',
  chunkId: chunkId ?? unit.chunk.id,
  sourceDigest: sourceDigest ?? unit.chunk.digest,
  synthesisFingerprint: 'fixture-os',
  duration: duration,
  cues:
      cues ??
      [
        NarrationCue(
          time: const Duration(milliseconds: 100),
          range: _range(0, 5),
          kind: NarrationCueKind.word,
        ),
        NarrationCue(
          time: const Duration(milliseconds: 600),
          range: _range(7, 12),
          kind: NarrationCueKind.word,
        ),
      ],
);

class _Fixture {
  _Fixture({NarrationPlaybackUnit? unit})
    : unit = unit ?? _unit('Hello, world.') {
    player.length = const Duration(seconds: 1);
    tracker = NarrationHighlightTracker(
      player: player,
      changed: () {
        changes.add(tracker.range);
        onChange?.call();
      },
    );
  }

  final FakeNarrationPlayer player = FakeNarrationPlayer();
  final Object owner = Object();
  final NarrationPlaybackUnit unit;
  final List<NarrationRange?> changes = [];
  late final NarrationHighlightTracker tracker;
  void Function()? onChange;
  int _nextToken = 0;
  NarrationTiming get timing => _timing(unit);

  Future<void> start(
    WidgetTester tester, {
    Duration offset = const Duration(milliseconds: 200),
    NarrationTiming? timing,
    bool markerless = false,
  }) async {
    final token = ++_nextToken;
    await player.load('fixture.wav', 'Book', token, offset);
    tracker.load(
      token: token,
      unit: unit,
      timing: markerless ? null : timing ?? this.timing,
    );
    await player.resume();
    await tester.pump();
  }

  Future<void> dispose(WidgetTester tester) async {
    // Cancel fake-clock timers before invariants; stream closure needs real I/O.
    await tester.runAsync(_disposeResources);
  }

  Future<void> _disposeResources() async {
    try {
      await tracker.dispose();
    } finally {
      await player.dispose();
    }
  }
}
