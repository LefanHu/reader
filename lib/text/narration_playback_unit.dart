import 'narration_chunk.dart';
import 'narration_range.dart';

/// Exact audio coverage and its enclosing native-tokenized sentence fallback.
/// A sentence may contain several clips; the fallback is not clip identity.
class NarrationPlaybackUnit {
  /// Binds exact audio coverage to a separate enclosing sentence fallback.
  const NarrationPlaybackUnit({required this.chunk, required this.sentence});

  /// Exact bounded source substring and natural-completion commit anchors.
  final NarrationChunk chunk;

  /// Native-tokenized decorative fallback; may encompass several clips.
  final NarrationRange sentence;
}
