// Persisted field meanings and lifecycle invariants are documented per model.
// ignore_for_file: public_member_api_docs

/// Reader-confirmed illustration settings for one publication.
class IllustrationProfile {
  const IllustrationProfile({
    required this.enabled,
    required this.style,
    required this.density,
    required this.styleVersion,
    required this.cloudBookId,
    this.analysisVersion = 2,
  });

  final bool enabled;
  final String style;
  final int density;
  final int styleVersion;

  /// Structured world-model schema used by newly scheduled chapter jobs.
  final int analysisVersion;
  final String cloudBookId;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'style': style,
    'density': density,
    'styleVersion': styleVersion,
    'analysisVersion': analysisVersion,
    'cloudBookId': cloudBookId,
  };

  factory IllustrationProfile.fromJson(Map<String, dynamic> json) =>
      IllustrationProfile(
        enabled: json['enabled'] as bool? ?? false,
        style: json['style'] as String? ?? '',
        density: (json['density'] as num?)?.round().clamp(1, 3) ?? 2,
        styleVersion: (json['styleVersion'] as num?)?.round() ?? 1,
        // Existing profiles adopt the current analyzer for newly scheduled
        // chapters; already-created job IDs remain untouched and idempotent.
        analysisVersion: (json['analysisVersion'] as num?)?.round() ?? 2,
        cloudBookId: json['cloudBookId'] as String? ?? '',
      );
}
