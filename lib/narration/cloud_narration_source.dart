import '../catalog/catalog_book.dart';
import '../text/narration.dart';
import '../text/narration_playback_unit.dart';
import '../text/narration_range.dart';
import '../text/text_position.dart';
import '../text/text_section.dart';
import 'api.dart';
import 'narration_audio_asset.dart';
import 'narration_cache_key.dart';
import 'narration_manifest.dart';
import 'narration_voice.dart';
import 'source.dart';
import 'store.dart';

/// The existing authenticated cloud generator retained for macOS.
class CloudNarrationSource implements NarrationSource {
  /// Keeps the real API boundary rather than mocking a local/cloud registration.
  CloudNarrationSource(this.api);

  /// Authenticated provider/privacy boundary retained independently of playback.
  final NarrationApi api;

  @override
  String get engine => 'openai-realtime';
  @override
  String get model => 'gpt-realtime-2.1-mini';
  @override
  String get format => 'pcm-24000-mono-v1';
  @override
  String get segmentationPolicy => 'cloud-paragraph-v1';
  @override
  String get synthesisFingerprint => 'gpt-realtime-2.1-mini';
  @override
  bool get requiresCloudRegistration => true;
  @override
  String get defaultVoice => 'marin';
  @override
  List<NarrationVoice> get voices => const [
    NarrationVoice(
      identifier: 'marin',
      name: 'Marin',
      language: 'en',
      quality: 'standard',
    ),
    NarrationVoice(
      identifier: 'cedar',
      name: 'Cedar',
      language: 'en',
      quality: 'standard',
    ),
  ];

  @override
  Future<List<NarrationPlaybackUnit>> units(
    TextSection section, {
    TextPosition? from,
    String? language,
  }) async => narrationChunks(section, from: from)
      .map((chunk) {
        final block = section.blocks.firstWhere(
          (block) => block.id == chunk.start.blockId,
        );
        return NarrationPlaybackUnit(
          chunk: chunk,
          sentence: NarrationRange(
            TextPosition(
              version: chunk.start.version,
              sectionId: section.id,
              blockId: block.id,
            ),
            TextPosition(
              version: chunk.start.version,
              sectionId: section.id,
              blockId: block.id,
              offset: block.text.length,
            ),
          ),
        );
      })
      .toList(growable: false);

  @override
  Future<NarrationAudioAsset> render(
    CatalogBook book,
    NarrationManifest profile,
    NarrationPlaybackUnit unit,
    NarrationStore store, {
    required int generation,
    required bool Function() isCurrent,
  }) async {
    final bookId = profile.cloudBookId;
    if (bookId == null || profile.account == null) {
      throw StateError('Cloud narration requires a genuine book registration.');
    }
    if (!voices.any((voice) => voice.identifier == profile.voice)) {
      throw StateError('Choose an available cloud narration voice.');
    }
    if (!isCurrent()) throw const NarrationCancelled();
    final bytes = await api.audio(
      bookId,
      unit.chunk,
      profile.voice,
      isCurrent: isCurrent,
    );
    if (!isCurrent()) throw const NarrationCancelled();
    final path = await store.put(
      book,
      narrationCacheKey(book, profile, unit.chunk),
      bytes,
      isCurrent: isCurrent,
    );
    return NarrationAudioAsset(path: path);
  }

  @override
  Future<void> cancel(int generation) async {
    // HTTP jobs are fenced by the caller's existing isCurrent contract. There is
    // no cancellation endpoint that could safely erase shared provider work.
  }
}
