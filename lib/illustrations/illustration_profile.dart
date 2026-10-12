// Persisted field meanings and lifecycle invariants are documented per model.
// ignore_for_file: public_member_api_docs

/// Reader-confirmed illustration settings for one publication.
/// Unknown provider IDs remain readable; availability must be checked before
/// admitting generation.
class IllustrationProfile {
  const IllustrationProfile({
    required this.enabled,
    required this.style,
    required this.density,
    required this.providerId,
    required this.revision,
    required this.cloudBookId,
  });

  final bool enabled;
  final String style;
  final int density;

  /// Saved source for future admissions, never retroactive ready-artwork state.
  final String providerId;

  /// Server-owned settings revision; 0 denotes an unsaved proposal.
  final int revision;

  final String cloudBookId;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'style': style,
    'density': density,
    'providerId': providerId,
    'revision': revision,
    'cloudBookId': cloudBookId,
  };

  factory IllustrationProfile.fromJson(Map<String, dynamic> json) {
    return IllustrationProfile(
      enabled: json['enabled'] as bool,
      style: json['style'] as String,
      density: json['density'] as int,
      providerId: json['providerId'] as String,
      revision: json['revision'] as int,
      cloudBookId: json['cloudBookId'] as String,
    );
  }
}
