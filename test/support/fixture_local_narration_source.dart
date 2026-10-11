import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/narration/narration_audio_asset.dart';
import 'package:reader/narration/narration_cache_key.dart';
import 'package:reader/narration/narration_manifest.dart';
import 'package:reader/narration/narration_voice.dart';
import 'package:reader/narration/source.dart';
import 'package:reader/narration/store.dart';
import 'package:reader/text/narration.dart';
import 'package:reader/text/narration_playback_unit.dart';
import 'package:reader/text/narration_range.dart';
import 'package:reader/text/text_position.dart';
import 'package:reader/text/text_section.dart';

import '../fixtures/narration_audio.dart';

/// Deterministic installed catalog/audio for UI tests, not native acceptance.
/// Whole-block units deliberately make no claims about Apple's tokenization.
class FixtureLocalNarrationSource implements NarrationSource {
  /// Preferred fixture identifier, unrelated to any device's installed voices.
  static const firstVoice = 'apple:fixture.preferred';

  /// Alternate fixture identifier for shared Settings/listening selection tests.
  static const secondVoice = 'apple:fixture.alternate';

  @override
  final List<NarrationVoice> voices = const [
    NarrationVoice(
      identifier: firstVoice,
      name: 'Avery',
      language: 'en-US',
      quality: 'Enhanced',
    ),
    NarrationVoice(
      identifier: secondVoice,
      name: 'Morgan — multilingual installed narration voice',
      language: 'en-GB',
      quality: 'Premium',
    ),
  ];

  @override
  String get engine => 'apple-avspeech';
  @override
  String get model => 'avspeech';
  @override
  String get format => 'apple-pcm16-native-v1';
  @override
  String get segmentationPolicy => 'apple-sentence-v1';
  @override
  String get synthesisFingerprint => 'fixture-os';
  @override
  bool get requiresCloudRegistration => false;
  @override
  String? get defaultVoice => firstVoice;

  /// Cache misses successfully rendered by this fixture.
  int renders = 0;
  final Set<int> _cancelled = {};

  @override
  Future<List<NarrationPlaybackUnit>> units(
    TextSection section, {
    TextPosition? from,
    String? language,
  }) async => [
    for (final chunk in narrationChunks(section, from: from))
      NarrationPlaybackUnit(
        chunk: chunk,
        sentence: NarrationRange(chunk.start, chunk.end),
      ),
  ];

  @override
  Future<NarrationAudioAsset> render(
    CatalogBook book,
    NarrationManifest profile,
    NarrationPlaybackUnit unit,
    NarrationStore store, {
    required int generation,
    required bool Function() isCurrent,
  }) async {
    if (_cancelled.contains(generation) || !isCurrent()) {
      throw const NarrationCancelled();
    }
    if (!voices.any((voice) => voice.identifier == profile.voice)) {
      throw StateError('Choose an installed voice for new audio.');
    }
    renders++;
    final key = narrationCacheKey(
      book,
      profile,
      unit.chunk,
      sentence: unit.sentence,
    );
    final path = await store.put(
      book,
      key,
      testWav(),
      isCurrent: () => isCurrent() && !_cancelled.contains(generation),
    );
    return NarrationAudioAsset(path: path);
  }

  @override
  Future<void> cancel(int generation) async {
    _cancelled.add(generation);
  }
}
