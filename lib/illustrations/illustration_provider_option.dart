// DTO fields mirror the server-owned provider catalogue contract.
// ignore_for_file: public_member_api_docs

/// Server-owned image source metadata; IDs remain strings so future sources
/// do not prevent reopening locally saved artwork.
class IllustrationProviderOption {
  /// Captures one server catalogue entry without resolving credentials locally.
  const IllustrationProviderOption({
    required this.id,
    required this.label,
    required this.model,
    required this.available,
    required this.recommended,
    required this.costTier,
    this.unavailableReason,
  });

  /// Stable request identity; unknown future IDs must not erase saved artwork.
  final String id;

  /// Server-owned display name, independent of the persisted identity.
  final String label;

  /// Informational model identity; clients never submit arbitrary model names.
  final String model;

  /// Deployment configuration, not a promise of successful live generation.
  final bool available;

  /// Server recommendation shown only when that source is configured.
  final bool recommended;

  /// Relative budget/balanced/premium hint, never a dollar billing guarantee.
  final String costTier;

  /// Safe operator-configuration explanation with no upstream error details.
  final String? unavailableReason;

  /// Parses authenticated server metadata without provider-key access.
  factory IllustrationProviderOption.fromJson(Map<String, dynamic> json) =>
      IllustrationProviderOption(
        id: json['id'] as String,
        label: json['label'] as String,
        model: json['model'] as String,
        available: json['available'] as bool,
        recommended: json['recommended'] as bool,
        costTier: json['costTier'] as String,
        unavailableReason: json['unavailableReason'] as String?,
      );
}
