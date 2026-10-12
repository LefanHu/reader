import 'dart:io';

import '../catalog/catalog_book.dart';
import '../text/grapheme_boundary.dart';
import '../text/narration_playback_unit.dart';
import '../text/narration_range.dart';
import '../text/sentence_narration.dart';
import '../text/text_position.dart';
import '../text/text_section.dart';
import 'apple_narration_service.dart';
import 'narration_audio_asset.dart';
import 'narration_cache_key.dart';
import 'narration_cue.dart';
import 'narration_manifest.dart';
import 'narration_timing.dart';
import 'narration_voice.dart';
import 'source.dart';
import 'store.dart';

/// Real installed-voice synthesis with native sentence segmentation. Failure is
/// recoverable locally; it never authenticates or falls back to cloud generation.
class AppleNarrationSource implements NarrationSource {
  AppleNarrationSource._(this.service);

  /// Retained with this source; native synthesizer ownership remains the engine.
  final AppleNarrationService service;

  /// Binds the store's private catalog root before requesting native synthesis.
  static Future<AppleNarrationSource> create({
    required Directory root,
    AppleNarrationService? service,
  }) async {
    final native = service ?? AppleNarrationService();
    await native.initialize(root);
    return AppleNarrationSource._(native);
  }

  @override
  String get engine => 'apple-avspeech';
  @override
  String get model => 'avspeech-default-rate';
  @override
  String get format => 'apple-pcm16-native';
  @override
  String get segmentationPolicy => appleSentenceNarrationPolicy;
  @override
  String get synthesisFingerprint => service.synthesisFingerprint;
  @override
  bool get requiresCloudRegistration => false;
  @override
  List<NarrationVoice> get voices => service.voices;
  @override
  String? get defaultVoice => service.defaultVoice;

  @override
  Future<List<NarrationPlaybackUnit>> units(
    TextSection section, {
    TextPosition? from,
    String? language,
  }) async => sentenceNarrationUnits(
    section,
    sentenceRanges: await service.sentenceRanges(section, language: language),
    from: from,
  );

  @override
  Future<NarrationAudioAsset> render(
    CatalogBook book,
    NarrationManifest profile,
    NarrationPlaybackUnit unit,
    NarrationStore store, {
    required int generation,
    required bool Function() isCurrent,
  }) async {
    if (!voices.any((voice) => voice.identifier == profile.voice)) {
      throw StateError(
        'The saved device voice is unavailable. Choose an installed voice.',
      );
    }
    if (!isCurrent()) throw const NarrationCancelled();
    final key = narrationCacheKey(
      book,
      profile,
      unit.chunk,
      sentence: unit.sentence,
    );
    return store.create(book, key, (stagingPath) async {
      if (!isCurrent()) throw const NarrationCancelled();
      final metadata = await service.synthesize(
        generation: generation,
        text: unit.chunk.text,
        voice: profile.voice,
        stagingPath: stagingPath,
        isCurrent: isCurrent,
      );
      if (!isCurrent()) throw const NarrationCancelled();
      return _timing(metadata, key: key, unit: unit);
    }, isCurrent: isCurrent);
  }

  /// Timing is optional. Only the probed native voice/OS/mono layout reports a
  /// verified utterance origin; no output-file byte width or WAV header is used.
  NarrationTiming? _timing(
    Map<String, dynamic> metadata, {
    required String key,
    required NarrationPlaybackUnit unit,
  }) {
    try {
      if (metadata['offsetOrigin'] != 'utterance' ||
          metadata['sourceChannels'] != 1) {
        return null;
      }
      final rate = (metadata['sampleRate'] as num).toDouble();
      final bytesPerFrame = metadata['sourceBytesPerFrame'] as int;
      final frames = metadata['frameCount'] as int;
      if (!rate.isFinite || rate <= 0 || frames <= 0 || bytesPerFrame <= 0) {
        return null;
      }
      final markers = metadata['markers'] as List;
      final text = unit.chunk.text;
      if (markers.isEmpty || markers.length > 2 * text.length + 2) return null;
      final boundaries = GraphemeBoundaries(text);
      final duration = Duration(
        microseconds: (frames * 1000000 / rate).round(),
      );
      final cues = <NarrationCue>[];
      for (final value in markers) {
        final marker = value as Map;
        final kind = switch (marker['kind']) {
          'word' => NarrationCueKind.word,
          'sentence' => NarrationCueKind.sentence,
          _ => null,
        };
        if (kind == null) continue;
        final byteOffset = marker['byteOffset'] as int;
        if (byteOffset < 0 ||
            byteOffset % bytesPerFrame != 0 ||
            byteOffset ~/ bytesPerFrame > frames) {
          return null;
        }
        final start = marker['utf16Start'] as int;
        final end = marker['utf16End'] as int;
        if (start < 0 || end > text.length || start >= end) continue;
        final first = boundaries.floor(start);
        final last = boundaries.ceil(end);
        if (first >= last) continue;
        TextPosition position(int relative) => TextPosition(
          sectionId: unit.chunk.start.sectionId,
          blockId: unit.chunk.start.blockId,
          offset: unit.chunk.start.offset + relative,
        );
        cues.add(
          NarrationCue(
            time: Duration(
              microseconds: (byteOffset / bytesPerFrame * 1000000 / rate)
                  .round(),
            ),
            range: NarrationRange(position(first), position(last)),
            kind: kind,
          ),
        );
      }
      if (cues.isEmpty) return null;
      return NarrationTiming(
        audioKey: key,
        chunkId: unit.chunk.id,
        sourceDigest: unit.chunk.digest,
        synthesisFingerprint: synthesisFingerprint,
        duration: duration,
        cues: cues,
      );
    } catch (_) {
      // Corrupt/unsupported metadata must never discard a playable native WAV.
      return null;
    }
  }

  @override
  Future<void> cancel(int generation) => service.cancelGeneration(generation);
}
