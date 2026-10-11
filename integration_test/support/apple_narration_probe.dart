import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/narration/narration_cache_key.dart';
import 'package:reader/text/narration_playback_unit.dart';
import 'package:reader/text/text_block.dart';
import 'package:reader/text/text_section.dart';

import 'native_test_app.dart';

/// Exercises the actual bridge's PCM layout, markers, tokenizer and decoded WAV.
/// Native metadata is evidence, not ASR or transcript-equality validation.
/// Runs under runWithFrames: synchronous matchers must not enter test guards
/// while that helper's tester.pump is active.
Future<void> probeAppleNarration(NativeTestApp app) async {
  final source = app.localNarrationSource!;
  expectSync(source.voices, isNotEmpty);
  final voice = source.defaultVoice ?? source.voices.first.identifier;
  final book = app.book('Unicode Test');
  final store = app.controller.narration!.store;
  final player = app.controller.narration!.player;
  var current = true;
  addTearDown(() async {
    current = false;
    await source.cancel(9000);
  });
  const passages = ['Hello, world. One, two, three.', '👩🏽‍🚀 é 中文 العربية.'];
  for (var index = 0; index < passages.length; index++) {
    final text = passages[index];
    final key = narrationFingerprintKey('reader-native-marker-probe-$index');
    final metadata = <String, dynamic>{};
    final asset = await store.create(book, key, (path) async {
      metadata.addAll(
        await source.service.synthesize(
          generation: 9000,
          text: text,
          voice: voice,
          stagingPath: path,
          isCurrent: () => current,
        ),
      );
      return null;
    }, isCurrent: () => current);
    // Negative probe-only tokens precede the session's positive load sequence.
    await player.load(
      asset.path,
      'Native marker probe',
      -2 + index,
      Duration.zero,
    );
    final rate = (metadata['sampleRate'] as num).toDouble();
    final frames = metadata['frameCount'] as int;
    final width = metadata['sourceBytesPerFrame'] as int;
    expectSync(rate, greaterThan(0));
    expectSync(frames, greaterThan(0));
    expectSync(width, greaterThan(0));
    expectSync(metadata['bufferCount'], greaterThan(1));
    expectSync(
      (player.duration!.inMicroseconds - (frames * 1000000 / rate).round())
          .abs(),
      lessThanOrEqualTo(1000),
    );
    final boundaries = <int>{0};
    var end = 0;
    for (final grapheme in text.characters) {
      end += grapheme.length;
      boundaries.add(end);
    }
    final cues = (metadata['markers'] as List).cast<Map>();
    final starts = <int>[];
    final evidence = <Map<String, Object>>[];
    for (final cue in cues) {
      final start = cue['utf16Start'] as int;
      final end = cue['utf16End'] as int;
      final byteOffset = cue['byteOffset'] as int;
      expectSync(start, inInclusiveRange(0, text.length - 1));
      expectSync(end, inInclusiveRange(start + 1, text.length));
      if (metadata['offsetOrigin'] == 'utterance') {
        expectSync(byteOffset % width, 0);
        expectSync(byteOffset ~/ width, inInclusiveRange(0, frames));
        starts.add(byteOffset);
      }
      // Apple's ranges can bisect a combining sequence. The source expands them
      // to complete source graphemes rather than slicing native string indices.
      final first = boundaries.lastWhere((value) => value <= start);
      final last = boundaries.firstWhere((value) => value >= end);
      evidence.add({
        'kind': cue['kind'] as String,
        'byteOffset': byteOffset,
        'rawStart': start,
        'rawEnd': end,
        'start': first,
        'end': last,
        'source': text.substring(first, last),
      });
    }
    if (starts.isNotEmpty) {
      expectSync(starts, orderedEquals(List<int>.of(starts)..sort()));
      if (text == passages.first) {
        expectSync(
          starts.last,
          greaterThan((metadata['maxBufferFrames'] as int) * width),
        );
        expectSync(
          evidence
              .where((cue) => cue['kind'] == 'word')
              .map((cue) => cue['source']),
          containsAll(['Hello,', 'world.', 'One,', 'two,', 'three.']),
        );
      }
    }
    debugPrint(
      'Reader native marker evidence: ${jsonEncode({'voice': voice, 'fingerprint': source.synthesisFingerprint, 'text': text, ...metadata, 'decodedDurationUs': player.duration!.inMicroseconds, 'graphemeSafeSourceCues': evidence})}',
    );
  }
  await source.cancel(9000);
  await player.stopAudio();

  // Real NLTokenizer boundaries, not a fake linguistic oracle. Exact source
  // reconstruction and complete graphemes are the stable acceptance contract.
  final section = TextSection(
    id: 'native-tokenizer-probe',
    blocks: [
      TextBlock(
        id: 'abbreviations',
        text: 'Dr. Lee paid 3.14. “Wait… really?” Next line.\nThen more.',
      ),
      TextBlock(
        id: 'punctuation-free',
        text: '中文没有句号 العربية بدون علامات é 👩🏽‍🚀',
      ),
      TextBlock(
        id: 'long-sentence',
        text:
            '${List.filled(20, 'An exact clause with é and 👩🏽‍🚀 stays in one sentence').join(', ')}.',
      ),
    ],
  );
  final units = await source.units(section, language: 'en');
  for (final block in section.blocks) {
    final spoken = units
        .where((unit) => unit.chunk.start.blockId == block.id)
        .toList();
    expectSync(spoken.map((unit) => unit.chunk.text).join(), block.text);
    _expectSafeUnits(block, spoken);
    if (block.id == 'long-sentence') {
      expectSync(spoken.length, greaterThan(1));
      expectSync(
        spoken.every((unit) => unit.sentence == spoken.first.sentence),
        isTrue,
      );
      expectSync(
        spoken.first.chunk.end.offset,
        lessThan(spoken.first.sentence.end.offset),
      );
    }
  }
}

void _expectSafeUnits(TextBlock block, List<NarrationPlaybackUnit> units) {
  final boundaries = <int>{0};
  var offset = 0;
  for (final grapheme in block.text.characters) {
    offset += grapheme.length;
    boundaries.add(offset);
  }
  for (final unit in units) {
    expectSync(boundaries, contains(unit.chunk.start.offset));
    expectSync(boundaries, contains(unit.chunk.end.offset));
    expectSync(boundaries, contains(unit.sentence.start.offset));
    expectSync(boundaries, contains(unit.sentence.end.offset));
    expectSync(unit.chunk.text.length, lessThanOrEqualTo(300));
  }
}
