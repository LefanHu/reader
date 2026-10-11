import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/narration/narration_cue.dart';
import 'package:reader/narration/narration_playback_clock.dart';
import 'package:reader/narration/session.dart';
import 'package:reader/text/narration_range.dart';
import 'package:reader/text/text_block.dart';
import 'package:reader/text/text_position.dart';
import 'package:reader/text/text_section.dart';

import 'support/local_narration_session_fixture.dart';

const _section = TextSection(
  id: 's0',
  blocks: [TextBlock(id: 'p0', text: 'Hello world.')],
);

TextPosition _position(int offset) =>
    TextPosition(sectionId: 's0', blockId: 'p0', offset: offset);
NarrationRange _range(int start, int end) =>
    NarrationRange(_position(start), _position(end));

List<NarrationCue> _wordCues() => [
  // A native sentence marker must not fill the gap before the first word cue.
  NarrationCue(
    time: Duration.zero,
    range: _range(0, 12),
    kind: NarrationCueKind.sentence,
  ),
  NarrationCue(
    time: const Duration(milliseconds: 100),
    range: _range(0, 5),
    kind: NarrationCueKind.word,
  ),
  NarrationCue(
    time: const Duration(milliseconds: 600),
    range: _range(6, 11),
    kind: NarrationCueKind.word,
  ),
];

Future<void> _events() => pumpEventQueue(times: 10);

void main() {
  group('Local session native-cue presentation with the real fake-player clock', () {
    late LocalNarrationSessionFixture fixture;
    late Object owner;

    setUp(() async {
      fixture = await LocalNarrationSessionFixture.create(sections: [_section]);
      fixture.source.timingFor = (request) => request.timing(_wordCues());
      owner = Object();
      fixture.session.attachHighlightOwner(owner);
      await fixture.session.attach(fixture.book);
    });
    tearDown(() => fixture.dispose());

    Future<void> clockAt(int milliseconds) async {
      fixture.player.position = Duration(milliseconds: milliseconds);
      fixture.player.emitClock();
      await _events();
    }

    test('100ms Hello / 600ms world are source ranges, not progress or forced sentence bounds', () async {
      await fixture.session.play();
      await clockAt(50);
      expect(fixture.session.activeHighlight, isNull);
      expect(fixture.anchor, _section.start);
      expect(fixture.commits, isEmpty);
      await clockAt(100);
      expect(fixture.session.activeHighlight, _range(0, 5));
      await clockAt(200);
      expect(fixture.session.activeHighlight, _range(0, 5));
      expect(fixture.session.activeFollowPosition, _position(0));
      expect(fixture.session.manifest.anchor, _section.start);
      expect(fixture.commits, isEmpty);

      await fixture.session.seek(const Duration(milliseconds: 650));
      await _events();
      expect(fixture.session.activeHighlight, _range(6, 11));
      expect(fixture.session.activeFollowPosition, _position(6));
      expect(fixture.anchor, _section.start);
      expect(fixture.commits, isEmpty);
      fixture.player.finish();
      await fixture.until(
        () => fixture.session.status == NarrationStatus.paused,
      );
      expect(fixture.session.activeHighlight, isNull);
      expect(
        fixture.commits,
        isEmpty,
      ); // A seeked tail is not whole-clip proof.

      // The conservative replay uses the persisted native timeline, not another
      // synthesis result, and only its natural ending commits the complete clip.
      fixture.source.timingFor = null;
      await fixture.session.play();
      await clockAt(50);
      expect(fixture.session.activeHighlight, isNull);
      await clockAt(650);
      expect(fixture.session.activeHighlight, _range(6, 11));
      expect(fixture.source.renders, 1);
      expect(fixture.commits, isEmpty);
      fixture.player.finish();
      await fixture.until(
        () => fixture.session.status == NarrationStatus.complete,
      );
      expect(fixture.session.activeHighlight, isNull);
      expect(fixture.commits, [_position(12)]);
      expect(fixture.progress, 1);
      expect(fixture.api.calls, isEmpty);
    });

    test('pause, resume and speed changes recompute native cues without synthesis or text writes', () async {
      await fixture.session.play();
      await clockAt(200);
      expect(fixture.session.activeHighlight, _range(0, 5));
      await fixture.session.configure(speed: 2);
      await _events();
      expect(fixture.player.multiplier, 2);
      expect(fixture.session.activeHighlight, _range(0, 5));
      await fixture.session.pause();
      expect(fixture.session.activeHighlight, isNull);
      expect(fixture.session.manifest.offsetMs, 200);
      expect(fixture.commits, isEmpty);

      await fixture.session.play();
      await _events();
      expect(fixture.player.loadedOffset, const Duration(milliseconds: 200));
      expect(fixture.session.activeHighlight, _range(0, 5));
      await clockAt(650);
      expect(fixture.session.activeHighlight, _range(6, 11));
      expect(fixture.source.renders, 1);
      expect(fixture.anchor, _section.start);
      expect(fixture.commits, isEmpty);
      fixture.player.finish();
      await fixture.until(
        () => fixture.session.status == NarrationStatus.complete,
      );
      expect(fixture.commits.single, _position(12));
    });

    test('stall and owner detachment clear the wash; reopening reads the current media position', () async {
      await fixture.session.play();
      await clockAt(200);
      expect(fixture.session.activeHighlight, _range(0, 5));
      fixture.player.ready = false;
      fixture.player.emitClock();
      await _events();
      expect(fixture.session.activeHighlight, isNull);
      expect(fixture.session.status, NarrationStatus.playing);
      fixture.player.ready = true;
      fixture.player.emitClock();
      await _events();
      expect(fixture.session.activeHighlight, _range(0, 5));

      fixture.session.detachHighlightOwner(owner);
      await clockAt(650);
      expect(fixture.session.activeHighlight, isNull);
      final replacementOwner = Object();
      fixture.session.attachHighlightOwner(replacementOwner);
      expect(fixture.session.activeHighlight, _range(6, 11));
      fixture.session.detachHighlightOwner(owner);
      expect(fixture.session.activeHighlight, _range(6, 11));
      fixture.session.detachHighlightOwner(replacementOwner);
      expect(fixture.session.activeHighlight, isNull);
      expect(fixture.source.renders, 1);
      expect(fixture.commits, isEmpty);
      expect(fixture.anchor, _section.start);
    });

    test('stale tokens and queued clock positions cannot override actual player position', () async {
      await fixture.session.play();
      final staleToken = fixture.player.token!;
      await fixture.session.playFrom(_section.start);
      final currentToken = fixture.player.token!;
      expect(currentToken, isNot(staleToken));
      await clockAt(200);
      fixture.player.clocks.add(
        NarrationPlaybackClock(
          token: staleToken,
          position: const Duration(milliseconds: 650),
          speed: 1,
          advancing: true,
        ),
      );
      await _events();
      expect(fixture.session.activeHighlight, _range(0, 5));
      fixture.player.clocks.add(
        NarrationPlaybackClock(
          token: currentToken,
          position: const Duration(milliseconds: 650),
          speed: 1,
          advancing: true,
        ),
      );
      await _events();
      expect(fixture.player.position, const Duration(milliseconds: 200));
      expect(fixture.session.activeHighlight, _range(0, 5));
      fixture.player.finish(staleToken);
      await _events();
      expect(fixture.session.activeHighlight, _range(0, 5));
      expect(fixture.player.token, currentToken);
      expect(fixture.commits, isEmpty);
      expect(fixture.anchor, _section.start);
    });

    test('native sentence cues are used when no word cues exist', () async {
      fixture.source.timingFor = (request) => request.timing([
        NarrationCue(
          time: const Duration(milliseconds: 100),
          range: _range(0, 5),
          kind: NarrationCueKind.sentence,
        ),
        NarrationCue(
          time: const Duration(milliseconds: 600),
          range: _range(6, 12),
          kind: NarrationCueKind.sentence,
        ),
      ]);
      await fixture.session.play();
      await clockAt(50);
      expect(fixture.session.activeHighlight, isNull);
      await clockAt(200);
      expect(fixture.session.activeHighlight, _range(0, 5));
      await clockAt(650);
      expect(fixture.session.activeHighlight, _range(6, 12));
      expect(fixture.commits, isEmpty);
      expect(fixture.anchor, _section.start);
    });

    test('synthesis callbacks and completed staging data do not highlight before playback', () async {
      final gate = fixture.source.hold(_section.start);
      final playing = fixture.session.play();
      await gate.started.future;
      expect(await File(gate.stagingPath!).exists(), isTrue);
      expect(fixture.session.status, NarrationStatus.buffering);
      expect(fixture.session.activeHighlight, isNull);
      expect(fixture.player.token, isNull);
      expect(fixture.commits, isEmpty);
      gate.release();
      await playing;
      await clockAt(50);
      expect(fixture.session.activeHighlight, isNull);
      await clockAt(200);
      expect(fixture.session.activeHighlight, _range(0, 5));
      expect(fixture.commits, isEmpty);
    });

    for (final incompatibility in [
      'unknown duration',
      'different duration',
      'fingerprint',
    ]) {
      test(
        '$incompatibility uses sentence fallback without rejecting playable audio',
        () async {
          if (incompatibility == 'unknown duration') {
            fixture.player.length = null;
          }
          if (incompatibility == 'different duration') {
            fixture.player.length = const Duration(milliseconds: 1002);
          }
          if (incompatibility == 'fingerprint') {
            fixture.source.timingFor = (request) => request.timing(
              _wordCues(),
              fingerprint: 'different-synthesis-os',
            );
          }
          await fixture.session.play();
          await clockAt(50);
          expect(fixture.session.status, NarrationStatus.playing);
          expect(fixture.session.activeHighlight, _range(0, 12));
          expect(fixture.source.renders, 1);
          expect(fixture.commits, isEmpty);
          expect(fixture.api.calls, isEmpty);
        },
      );
    }

    test('one millisecond player-duration rounding still permits matching native timing', () async {
      fixture.player.length = const Duration(milliseconds: 1001);
      await fixture.session.play();
      await clockAt(50);
      expect(fixture.session.activeHighlight, isNull);
      await clockAt(200);
      expect(fixture.session.activeHighlight, _range(0, 5));
      expect(fixture.source.renders, 1);
      expect(fixture.commits, isEmpty);
    });

    for (final corruption in ['missing', 'corrupt']) {
      test(
        '$corruption timing companion keeps cached audio playable with sentence fallback',
        () async {
          await fixture.session.play();
          await clockAt(200);
          expect(fixture.session.activeHighlight, _range(0, 5));
          await fixture.session.pause();
          final request = fixture.source.requests.single;
          final companion = File(
            '${File(fixture.book.path).parent.path}/narration/${request.key}.timing.json',
          );
          expect(await companion.exists(), isTrue);
          if (corruption == 'missing') {
            await companion.delete();
          } else {
            await companion.writeAsString('{invalid timing', flush: true);
          }
          fixture.source.timingFor = (_) =>
              throw StateError('Cached audio must not regenerate.');
          await fixture.session.play();
          await _events();
          expect(fixture.session.status, NarrationStatus.playing);
          expect(
            fixture.player.loadedOffset,
            const Duration(milliseconds: 200),
          );
          expect(fixture.session.activeHighlight, _range(0, 12));
          expect(
            (await fixture.store.cached(fixture.book, request.key))!.timing,
            isNull,
          );
          expect(fixture.source.renders, 1);
          expect(fixture.commits, isEmpty);
          expect(fixture.api.calls, isEmpty);
        },
      );
    }
  });
}
