/// Installed or provider-owned voice exposed by the selected narration engine.
/// Apple preference identifiers are namespaced; raw native identifiers never
/// overlap the real cloud provider's Marin/Cedar values.
class NarrationVoice {
  /// Describes one genuine selectable catalog entry from the active source.
  const NarrationVoice({
    required this.identifier,
    required this.name,
    required this.language,
    required this.quality,
  });

  /// Device-local namespaced identifier or real cloud-provider voice name.
  final String identifier;

  /// Human-readable installed/provider voice name.
  final String name;

  /// BCP-47 language exposed by the underlying voice catalog.
  final String language;

  /// Native/provider quality label used in the shared settings controls.
  final String quality;
}
