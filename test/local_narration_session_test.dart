import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/catalog/file_catalog_store.dart';
import 'package:reader/narration/narration_cache_key.dart';
import 'package:reader/narration/narration_manifest.dart';
import 'package:reader/narration/session.dart';
import 'package:reader/narration/source.dart';
import 'package:reader/text/narration_range.dart';
import 'package:reader/text/text_block.dart';
import 'package:reader/text/text_position.dart';
import 'package:reader/text/text_section.dart';

import 'fixtures/narration_audio.dart';
import 'support/fixture_local_narration_source.dart';
import 'support/local_narration_session_fixture.dart';

const _sections = [
  TextSection(
    id: 's0',
    blocks: [
      TextBlock(id: 'p0', text: 'One. Two. Three. Four.'),
      TextBlock(id: 'p1', text: 'Next paragraph.'),
    ],
  ),
  TextSection(
    id: 's1',
    blocks: [TextBlock(id: 'p2', text: 'Final sentence.')],
  ),
];

// Explicit source-boundary fixtures, not assertions about NLTokenizer behavior.
const _sentenceRanges = {
  'p0': [
    (start: 0, end: 4),
    (start: 5, end: 9),
    (start: 10, end: 16),
    (start: 17, end: 22),
  ],
};
const _helloSections = [
  TextSection(
    id: 's0',
    blocks: [TextBlock(id: 'p0', text: 'Hello world.')],
  ),
];

TextPosition _position(
  int offset, {
  String section = 's0',
  String block = 'p0',
}) => TextPosition(sectionId: section, blockId: block, offset: offset);

NarrationManifest _localManifest(
  LocalNarrationSessionFixture fixture, {
  required TextPosition anchor,
  required TextPosition start,
  required String chunkId,
  String voice = FixtureLocalNarrationSource.firstVoice,
  String? fingerprint,
  int offsetMs = 375,
}) => NarrationManifest(
  voice: voice,
  engine: fixture.source.engine,
  synthesisFingerprint: fingerprint ?? fixture.source.synthesisFingerprint,
  segmentationPolicy: fixture.source.segmentationPolicy,
  anchor: anchor,
  chunkStart: start,
  chunkId: chunkId,
  offsetMs: offsetMs,
);

Future<void> _clockEvents() => pumpEventQueue(times: 10);

void main() {
  group('Local session readiness and exact clip progress', () {
    late LocalNarrationSessionFixture fixture;

    setUp(() async {
      fixture = await LocalNarrationSessionFixture.create(
        sections: _sections,
        sentenceRanges: _sentenceRanges,
      );
    });
    tearDown(() => fixture.dispose());

    test(
      'null account and cloud ID allow registration-free play and flush',
      () async {
        final session = fixture.session;
        expect(session.ready, isFalse);
        await session.register(fixture.book);
        expect(session.ready, isTrue);
        expect(session.manifest.account, isNull);
        expect(session.manifest.cloudBookId, isNull);
        expect(session.remaining, isNull);

        await session.play();
        expect(session.status, NarrationStatus.playing);
        expect(fixture.player.playing, isTrue);
        await session.pause();
        await session.flush();
        final saved = await fixture.store.load(fixture.book);
        expect(saved.engine, 'apple-avspeech');
        expect(saved.segmentationPolicy, 'apple-sentence');
        expect(saved.synthesisFingerprint, fixture.source.synthesisFingerprint);
        expect(saved.account, isNull);
        expect(saved.cloudBookId, isNull);
        expect(fixture.api.calls, isEmpty);
        expect(fixture.commits, isEmpty);
        expect(fixture.anchor, _sections.first.start);
      },
    );

    test(
      'the first short clip plays while the next clip writer is still pending',
      () async {
        final next = fixture.source.hold(_position(5));
        final lastLookahead = fixture.source.hold(_position(10));
        await fixture.session.attach(fixture.book);
        await fixture.session.play().timeout(const Duration(seconds: 5));
        await next.started.future;

        expect(fixture.session.status, NarrationStatus.playing);
        expect(fixture.player.playing, isTrue);
        expect(fixture.session.activeChunk!.text, 'One. ');
        expect(fixture.session.activeChunk!.end, _position(5));
        expect(fixture.source.requests.length, 2);
        expect(fixture.source.requests.first.asset, isNotNull);
        expect(fixture.source.requests.last.asset, isNull);
        expect(fixture.source.requests.last.finished.isCompleted, isFalse);
        expect(
          await File(fixture.source.requests.first.asset!.path).exists(),
          isTrue,
        );
        expect(fixture.commits, isEmpty);
        expect(fixture.api.calls, isEmpty);
        next.release();
        await fixture.source.requests.last.finished.future;
        await lastLookahead.started.future;
        expect(fixture.source.requests.length, 3);
        expect(
          fixture.source.requests.map((request) => request.unit.chunk.start),
          [_position(0), _position(5), _position(10)],
        );
        expect(fixture.player.playing, isTrue);
        expect(fixture.commits, isEmpty);
        lastLookahead.release();
        await fixture.source.requests.last.finished.future;
      },
    );

    test('only natural clip endings commit, through paragraph and section boundaries to EOF', () async {
      final units = [
        for (final section in _sections) ...await fixture.source.units(section),
      ];
      await fixture.session.attach(fixture.book);
      await fixture.session.play();
      final initial = fixture.anchor;
      for (var i = 0; i < units.length; i++) {
        final unit = units[i];
        expect(fixture.session.activeChunk!.start, unit.chunk.start);
        expect(fixture.session.activeChunk!.end, unit.chunk.end);
        expect(fixture.commits, units.take(i).map((item) => item.chunk.end));
        await fixture.session.flush();
        expect(fixture.commits.length, i);
        expect(fixture.anchor, i == 0 ? initial : units[i - 1].chunk.end);

        fixture.player.finish();
        if (i + 1 == units.length) {
          await fixture.until(
            () => fixture.session.status == NarrationStatus.complete,
          );
        } else {
          await fixture.until(
            () =>
                fixture.session.status == NarrationStatus.playing &&
                fixture.session.activeChunk?.start == units[i + 1].chunk.start,
          );
        }
        expect(fixture.commits.last, unit.chunk.end);
        if (unit.chunk.end.blockId == 'p0' && unit.chunk.end.offset < 22) {
          // A partial sentence/block completion cannot open a paragraph-end gate.
          expect(
            fixture.anchor.offset,
            lessThan(_sections.first.blocks.first.text.length),
          );
        }
      }
      expect(fixture.commits, units.map((unit) => unit.chunk.end));
      expect(fixture.anchor, _position(15, section: 's1', block: 'p2'));
      expect(fixture.progress, 1);
      expect(fixture.session.activeChunk, isNull);
      expect(fixture.session.activeHighlight, isNull);
      expect((await fixture.store.load(fixture.book)).anchor, fixture.anchor);
      expect(fixture.api.calls, isEmpty);
    });

    test(
      'replacement playback ignores the previous native completion token',
      () async {
        await fixture.session.attach(fixture.book);
        await fixture.session.play();
        final oldToken = fixture.player.token!;
        final selected = _position(0, block: 'p1');
        await fixture.session.playFrom(selected);
        final replacementToken = fixture.player.token;
        expect(replacementToken, isNot(oldToken));
        fixture.player.finish(oldToken);
        await _clockEvents();
        expect(fixture.commits, isEmpty);
        expect(fixture.session.activeChunk!.start, selected);
        expect(fixture.player.token, replacementToken);
        expect(fixture.anchor, _sections.first.start);

        fixture.player.finish();
        await fixture.until(
          () =>
              fixture.session.status == NarrationStatus.playing &&
              fixture.session.activeChunk?.start.sectionId == 's1',
        );
        expect(fixture.commits.single, _position(15, block: 'p1'));
        expect(fixture.api.calls, isEmpty);
      },
    );
  });

  group('Local interrupted offsets and generation identity', () {
    late LocalNarrationSessionFixture fixture;

    setUp(() async {
      fixture = await LocalNarrationSessionFixture.create(
        sections: _helloSections,
      );
      await fixture.session.attach(fixture.book);
    });
    tearDown(() => fixture.dispose());

    test('media pause persists audio offset without committing and cached resume reuses it', () async {
      final restorations = <TextPosition>[];
      fixture.session.restoreViewport = (_, anchor) async =>
          restorations.add(anchor);
      await fixture.session.play();
      fixture.player.position = const Duration(milliseconds: 350);
      await fixture.player.remotePause!();
      final saved = await fixture.store.load(fixture.book);
      expect(saved.offsetMs, 350);
      expect(saved.chunkStart, _helloSections.first.start);
      expect(saved.anchor, _helloSections.first.start);
      expect(restorations, [_helloSections.first.start]);
      expect(fixture.commits, isEmpty);
      expect(fixture.session.activeHighlight, isNull);

      final renders = fixture.source.renders;
      await fixture.player.remotePlay!();
      expect(fixture.player.loadedOffset, const Duration(milliseconds: 350));
      expect(fixture.source.renders, renders);
      expect(fixture.commits, isEmpty);
      fixture.player.finish();
      await fixture.until(
        () => fixture.session.status == NarrationStatus.complete,
      );
      expect(fixture.commits.single, _position(12));
      expect(fixture.api.calls, isEmpty);
    });

    test('seeked tail completion cannot commit; conservative replay starts at zero', () async {
      await fixture.session.play();
      await fixture.session.seek(const Duration(seconds: 1));
      expect(fixture.player.position, const Duration(milliseconds: 999));
      expect(fixture.session.manifest.chunkId, isNull);
      expect(fixture.session.manifest.chunkStart, isNull);
      expect(fixture.session.manifest.offsetMs, 0);
      expect(fixture.commits, isEmpty);
      fixture.player.finish();
      await fixture.until(
        () => fixture.session.status == NarrationStatus.paused,
      );
      expect(fixture.commits, isEmpty);
      expect(fixture.anchor, _helloSections.first.start);

      await fixture.session.play();
      expect(fixture.player.loadedOffset, Duration.zero);
      expect(fixture.source.renders, 1);
      fixture.player.finish();
      await fixture.until(
        () => fixture.session.status == NarrationStatus.complete,
      );
      expect(fixture.commits.single, _position(12));
    });

    test('speed reuses audio; voice changes pause and invalidate offsets without generating or committing', () async {
      await fixture.session.play();
      fixture.player.position = const Duration(milliseconds: 400);
      await fixture.session.flush();
      final token = fixture.player.token;
      final firstRequest = fixture.source.requests.single;
      await fixture.session.configure(speed: 1.5);
      expect(fixture.player.multiplier, 1.5);
      expect(fixture.player.token, token);
      expect(fixture.player.playing, isTrue);
      expect(fixture.source.renders, 1);
      expect(fixture.session.manifest.chunkId, firstRequest.unit.chunk.id);
      expect(fixture.session.manifest.offsetMs, 400);
      expect(fixture.commits, isEmpty);

      await fixture.session.configure(
        voice: FixtureLocalNarrationSource.secondVoice,
      );
      expect(fixture.player.playing, isFalse);
      expect(fixture.session.status, NarrationStatus.paused);
      expect(fixture.source.renders, 1);
      expect(fixture.session.manifest.chunkId, isNull);
      expect(fixture.session.manifest.offsetMs, 0);
      expect(fixture.session.manifest.anchor, _helloSections.first.start);
      expect(fixture.session.manifest.chunkStart, _helloSections.first.start);
      expect(fixture.commits, isEmpty);

      await fixture.session.play();
      final replacement = fixture.source.requests.last;
      expect(fixture.source.renders, 2);
      expect(
        replacement.profile.voice,
        FixtureLocalNarrationSource.secondVoice,
      );
      expect(replacement.key, isNot(firstRequest.key));
      expect(fixture.player.loadedOffset, Duration.zero);
      expect(fixture.player.multiplier, 1.5);
      expect(
        await fixture.store.cached(fixture.book, firstRequest.key),
        isNotNull,
      );
      expect(fixture.commits, isEmpty);
      expect(fixture.api.calls, isEmpty);
    });

    test(
      'an unknown installed-voice selection cannot mutate playback',
      () async {
        await fixture.session.play();
        final token = fixture.player.token;
        expect(
          () => fixture.session.configure(voice: 'apple:fixture.missing'),
          throwsArgumentError,
        );
        expect(fixture.player.token, token);
        expect(fixture.player.playing, isTrue);
        expect(
          fixture.session.manifest.voice,
          FixtureLocalNarrationSource.firstVoice,
        );
        expect(fixture.source.renders, 1);
        expect(fixture.commits, isEmpty);
      },
    );

    test(
      'a native speech rejection shows its cause, not the raw exception',
      () async {
        fixture.source.timingFor = (_) => throw PlatformException(
          code: 'narration_voice',
          message: 'The selected voice is not installed on this device.',
        );
        await fixture.session.play();
        expect(
          fixture.session.error,
          'The selected voice is not installed on this device.',
        );
        expect(fixture.commits, isEmpty);
      },
    );

    for (final operation in [
      'pause',
      'navigation',
      'voice change',
      'cache clear',
      'deletion',
    ]) {
      test(
        '$operation fences the active native completion without advancing the catalog',
        () async {
          await fixture.session.play();
          final token = fixture.player.token!;
          fixture.player.position = const Duration(milliseconds: 700);
          switch (operation) {
            case 'pause':
              await fixture.session.pause();
            case 'navigation':
              await fixture.session.navigate(fixture.book);
            case 'voice change':
              await fixture.session.configure(
                voice: FixtureLocalNarrationSource.secondVoice,
              );
            case 'cache clear':
              await fixture.session.clear();
            case 'deletion':
              await fixture.session.detach(fixture.book);
              fixture.deleted.add(fixture.book.hash);
              await FileCatalogStore(fixture.root).deleteFiles(fixture.book);
          }
          fixture.player.finish(token);
          await _clockEvents();
          expect(fixture.commits, isEmpty);
          expect(fixture.anchor, _helloSections.first.start);
          expect(fixture.player.playing, isFalse);
          expect(fixture.session.activeHighlight, isNull);
          expect(fixture.api.calls, isEmpty);
          if (operation == 'deletion') {
            expect(fixture.session.book, isNull);
            expect(await File(fixture.book.path).parent.exists(), isFalse);
          } else {
            final saved = await fixture.store.load(fixture.book);
            expect(saved.engine, fixture.source.engine);
            expect(
              saved.synthesisFingerprint,
              fixture.source.synthesisFingerprint,
            );
            if (operation == 'pause') {
              expect(saved.offsetMs, 700);
              expect(saved.chunkStart, _helloSections.first.start);
            } else {
              expect(saved.chunkId, isNull);
              expect(saved.offsetMs, 0);
            }
            if (operation == 'cache clear') {
              expect(await fixture.store.cachedBytes(fixture.book), 0);
              expect(saved.anchor, _helloSections.first.start);
            }
          }
        },
      );
    }
  });

  group('Stale local synthesis cannot publish or grant progress', () {
    late LocalNarrationSessionFixture fixture;

    setUp(() async {
      fixture = await LocalNarrationSessionFixture.create(
        sections: _sections,
        sentenceRanges: _sentenceRanges,
      );
      await fixture.session.attach(fixture.book);
    });
    tearDown(() => fixture.dispose());

    for (final operation in [
      'pause',
      'navigation',
      'voice change',
      'cache clear',
      'deletion',
    ]) {
      test(
        '$operation settles a pending writer and rejects its stale successful result',
        () async {
          final gate = fixture.source.hold(_sections.first.start);
          final playing = fixture.session.play();
          await gate.started.future;
          final request = fixture.source.requests.single;
          expect(request.isCurrent(), isTrue);
          expect(await File(gate.stagingPath!).exists(), isTrue);
          switch (operation) {
            case 'pause':
              await fixture.session.pause();
            case 'navigation':
              await fixture.session.navigate(fixture.book);
            case 'voice change':
              await fixture.session.configure(
                voice: FixtureLocalNarrationSource.secondVoice,
              );
            case 'cache clear':
              await fixture.session.clear();
            case 'deletion':
              await fixture.session.detach(fixture.book);
              fixture.deleted.add(fixture.book.hash);
              await FileCatalogStore(fixture.root).deleteFiles(fixture.book);
          }
          gate.release(); // A late success cannot reopen the already settled writer.
          await playing;
          await request.finished.future;
          expect(gate.cancelled, isTrue);
          expect(request.isCurrent(), isFalse);
          expect(request.failure, isA<NarrationCancelled>());
          expect(request.asset, isNull);
          expect(
            fixture.source.cancelledGenerations,
            contains(request.generation),
          );
          expect(await File(gate.stagingPath!).exists(), isFalse);
          expect(fixture.player.playing, isFalse);
          expect(fixture.commits, isEmpty);
          expect(fixture.anchor, _sections.first.start);
          expect(fixture.api.calls, isEmpty);
          if (operation == 'deletion') {
            expect(fixture.session.book, isNull);
            expect(fixture.session.status, NarrationStatus.idle);
            expect(await File(fixture.book.path).parent.exists(), isFalse);
          } else {
            expect(
              await fixture.store.cached(fixture.book, request.key),
              isNull,
            );
            expect(await fixture.store.cachedBytes(fixture.book), 0);
            expect(fixture.session.status, NarrationStatus.paused);
          }
          if (operation == 'navigation') {
            final manual = _position(0, block: 'p1');
            fixture.positions[fixture.book.hash] = manual;
            fixture.anchor = manual;
            await fixture.session.play();
            expect(fixture.session.activeChunk!.start, manual);
            expect(fixture.player.loadedOffset, Duration.zero);
            expect(fixture.commits, isEmpty);
          }
          if (operation == 'cache clear') {
            final saved = await fixture.store.load(fixture.book);
            expect(saved.anchor, _sections.first.start);
            expect(saved.chunkId, isNull);
            expect(saved.offsetMs, 0);
            expect(saved.engine, fixture.source.engine);
            expect(
              saved.synthesisFingerprint,
              fixture.source.synthesisFingerprint,
            );
          }
        },
      );
    }

    test('replacement can retry the identical clip while its old writer is cancelled', () async {
      final gate = fixture.source.hold(_sections.first.start);
      final oldPlayback = fixture.session.play();
      await gate.started.future;
      final stale = fixture.source.requests.single;
      await fixture.session.playFrom(_sections.first.start);
      final token = fixture.player.token;
      gate.release();
      await oldPlayback;
      final replacements = fixture.source.requests
          .where((request) => request.unit.chunk.start == _sections.first.start)
          .toList();
      expect(replacements.length, 2);
      expect(replacements.last.key, stale.key);
      expect(replacements.last.generation, isNot(stale.generation));
      expect(stale.asset, isNull);
      expect(stale.failure, isA<NarrationCancelled>());
      expect(replacements.last.asset, isNotNull);
      expect(fixture.player.token, token);
      expect(fixture.session.status, NarrationStatus.playing);
      expect(fixture.commits, isEmpty);
    });

    test('pause cancels speculative synthesis but retains the already playable first file', () async {
      final gate = fixture.source.hold(_position(5));
      await fixture.session.play();
      await gate.started.future;
      final first = fixture.source.requests.first;
      final speculative = fixture.source.requests.last;
      await fixture.session.pause();
      expect(gate.cancelled, isTrue);
      expect(await fixture.store.cached(fixture.book, first.key), isNotNull);
      expect(await fixture.store.cached(fixture.book, speculative.key), isNull);
      expect(fixture.source.requests.length, 2);
      expect(fixture.commits, isEmpty);
      expect(fixture.session.activeHighlight, isNull);
    });

    test('switching publications fences the old writer and isolates cache ownership', () async {
      final other = await fixture.secondBook();
      final gate = fixture.source.hold(_sections.first.start);
      final oldPlayback = fixture.session.play();
      await gate.started.future;
      final abandoned = fixture.source.requests.single;
      await fixture.session.attach(other);
      await fixture.session.play();
      gate.release();
      await oldPlayback;
      final current = fixture.source.requests.firstWhere(
        (request) => request.book.hash == other.hash,
      );
      expect(fixture.session.book!.hash, other.hash);
      expect(fixture.session.ready, isTrue);
      expect(current.key, isNot(abandoned.key));
      expect(current.asset, isNotNull);
      expect(await fixture.store.cached(fixture.book, abandoned.key), isNull);
      expect(fixture.positions[fixture.book.hash], _sections.first.start);
      expect(fixture.positions[other.hash], _sections.first.start);
      expect(fixture.commits, isEmpty);
      expect(fixture.api.calls, isEmpty);
    });
  });

  group('Complete logical anchors survive local identity migration', () {
    late LocalNarrationSessionFixture fixture;
    final committed = _position(2);
    final playbackStart = _position(6, section: 's1', block: 'p2');

    setUp(() async {
      fixture = await LocalNarrationSessionFixture.create(
        sections: _sections,
        sentenceRanges: _sentenceRanges,
        anchor: committed,
      );
    });
    tearDown(() => fixture.dispose());

    for (final mismatch in ['voice', 'fingerprint', 'engine/policy']) {
      test(
        '$mismatch invalidates audio offset but preserves both full logical anchors',
        () async {
          final unit = (await fixture.source.units(
            _sections.last,
            from: playbackStart,
          )).single;
          final old = mismatch == 'engine/policy'
              ? NarrationManifest(
                  account: 'old-account',
                  cloudBookId: 'old-registration',
                  voice: 'marin',
                  anchor: committed,
                  chunkStart: playbackStart,
                  chunkId: unit.chunk.id,
                  offsetMs: 700,
                )
              : _localManifest(
                  fixture,
                  anchor: committed,
                  start: playbackStart,
                  chunkId: unit.chunk.id,
                  voice: mismatch == 'voice'
                      ? FixtureLocalNarrationSource.secondVoice
                      : FixtureLocalNarrationSource.firstVoice,
                  fingerprint: mismatch == 'fingerprint' ? 'previous-os' : null,
                );
          final oldKey = narrationCacheKey(
            fixture.book,
            old,
            unit.chunk,
            sentence: unit.sentence,
          );
          await fixture.store.save(fixture.book, old);
          await fixture.store.put(fixture.book, oldKey, testWav());
          await fixture.session.attach(fixture.book);
          final migrated = await fixture.store.load(fixture.book);
          expect(migrated.anchor, committed);
          expect(migrated.chunkStart, playbackStart);
          expect(migrated.chunkId, isNull);
          expect(migrated.offsetMs, 0);
          expect(migrated.voice, FixtureLocalNarrationSource.firstVoice);
          expect(migrated.engine, fixture.source.engine);
          expect(
            migrated.segmentationPolicy,
            fixture.source.segmentationPolicy,
          );
          expect(
            migrated.synthesisFingerprint,
            fixture.source.synthesisFingerprint,
          );
          await fixture.session.play();
          expect(fixture.player.loadedOffset, Duration.zero);
          expect(fixture.session.activeChunk!.start, playbackStart);
          expect(fixture.source.requests.single.key, isNot(oldKey));
          expect(await fixture.store.cached(fixture.book, oldKey), isNotNull);
          expect(fixture.commits, isEmpty);
          expect(fixture.anchor, committed);
        },
      );
    }

    test('matching local identity resumes the exact saved suffix and cached media offset', () async {
      final unit = (await fixture.source.units(
        _sections.last,
        from: playbackStart,
      )).single;
      final saved = _localManifest(
        fixture,
        anchor: committed,
        start: playbackStart,
        chunkId: unit.chunk.id,
      );
      final key = narrationCacheKey(
        fixture.book,
        saved,
        unit.chunk,
        sentence: unit.sentence,
      );
      await fixture.store.save(fixture.book, saved);
      await fixture.store.put(fixture.book, key, testWav());
      await fixture.session.attach(fixture.book);
      await fixture.session.play();
      expect(fixture.player.loadedOffset, const Duration(milliseconds: 375));
      expect(fixture.session.activeChunk!.start, playbackStart);
      expect(fixture.session.activeChunk!.text, 'sentence.');
      expect(fixture.source.requests, isEmpty);
      expect(fixture.session.manifest.anchor, committed);
      expect(fixture.session.manifest.account, isNull);
      expect(fixture.session.manifest.cloudBookId, isNull);
      expect(fixture.commits, isEmpty);
      expect(fixture.api.calls, isEmpty);
    });
  });

  test('long authored sentence uses bounded first clip and keeps fallback identity separate', () async {
    final prose = '${'word ' * 140}tail.';
    final section = TextSection(
      id: 's0',
      blocks: [TextBlock(id: 'p0', text: prose)],
    );
    final fixture = await LocalNarrationSessionFixture.create(
      sections: [section],
      sentenceRanges: {
        'p0': [(start: 0, end: prose.length)],
      },
    );
    addTearDown(() => fixture.dispose());
    final units = await fixture.source.units(section);
    final fallback = NarrationRange(section.start, _position(prose.length));
    final owner = Object();
    fixture.session.attachHighlightOwner(owner);
    await fixture.session.attach(fixture.book);
    await fixture.session.play();
    await _clockEvents();
    expect(units.length, greaterThan(1));
    expect(fixture.session.activeChunk!.text.length, lessThanOrEqualTo(300));
    expect(fixture.session.activeHighlight, fallback);
    expect(
      fixture.session.activeChunk!.end.offset,
      lessThan(fallback.end.offset),
    );
    expect(fixture.commits, isEmpty);
    fixture.player.finish();
    await fixture.until(
      () =>
          fixture.session.status == NarrationStatus.playing &&
          fixture.session.activeChunk?.start == units[1].chunk.start,
    );
    expect(fixture.commits.single, units.first.chunk.end);
    expect(fixture.progress, lessThan(1));
    expect(fixture.anchor.offset, lessThan(prose.length));
    expect(fixture.session.activeHighlight, fallback);
    expect(fixture.session.activeFollowPosition, units[1].chunk.start);
    expect(fixture.session.activeFollowPosition, isNot(fallback.start));
    fixture.session.detachHighlightOwner(owner);
    expect(fixture.api.calls, isEmpty);
  });
}
