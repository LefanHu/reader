import '../catalog/catalog_book.dart';
import '../text/narration_playback_unit.dart';
import '../text/text_position.dart';
import '../text/text_section.dart';
import 'narration_audio_asset.dart';
import 'narration_manifest.dart';
import 'narration_voice.dart';
import 'store.dart';

/// Generation boundary selected at composition, never a cloud fallback router.
/// Playback speed belongs to the existing file player, not synthesis identity.
abstract interface class NarrationSource {
  /// Engine identity persisted in resume state, independent of a cloud account.
  String get engine;

  /// Actual synthesis model/rate policy, without playback speed.
  String get model;

  /// File-format policy; local PCM keeps the native rate/channel layout.
  String get format;

  /// Source-specific batching identity, not the server's chunk protocol version.
  String get segmentationPolicy;

  /// Provider or OS build identity that fences incompatible cached offsets.
  String get synthesisFingerprint;

  /// Only the cloud source waits for genuine authenticated book registration.
  bool get requiresCloudRegistration;

  /// Snapshot of genuinely available voices; saved missing voices remain honest.
  List<NarrationVoice> get voices;

  /// Preference identifier for the device's language, or null if unavailable.
  String? get defaultVoice;

  /// Segments already normalized text, preserving exact complete suffix anchors.
  /// Language is a tokenizer hint, never a second normalization/extraction step.
  Future<List<NarrationPlaybackUnit>> units(
    TextSection section, {
    TextPosition? from,
    String? language,
  });

  /// Publishes through the supplied store. Stale work must not publish audio or
  /// mutate reading progress; timing failure cannot reject otherwise valid audio.
  Future<NarrationAudioAsset> render(
    CatalogBook book,
    NarrationManifest profile,
    NarrationPlaybackUnit unit,
    NarrationStore store, {
    required int generation,
    required bool Function() isCurrent,
  });

  /// Cancels and settles pending native work outside the store's write queue.
  Future<void> cancel(int generation);
}
