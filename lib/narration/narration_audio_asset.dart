import 'narration_timing.dart';

/// A published playable audio file with optional, independently valid timing.
class NarrationAudioAsset {
  /// Wraps an owned published file; absent timing uses sentence fallback.
  const NarrationAudioAsset({required this.path, this.timing});

  /// Absolute playable file path chosen and published by the store.
  final String path;

  /// Optional native marker timeline, independently validated from the audio.
  final NarrationTiming? timing;
}
