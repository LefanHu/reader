// DTO fields mirror the server-owned configuration contract.
// ignore_for_file: public_member_api_docs

import 'illustration_provider_option.dart';

/// Authenticated, uncached server availability; contains no provider secrets.
class IllustrationConfiguration {
  /// Captures a read-only availability snapshot; consent is stored separately.
  const IllustrationConfiguration({
    required this.enabled,
    required this.defaultProviderId,
    required this.providers,
  });

  /// Rollout admission gate, independent of cached artwork readability.
  final bool enabled;

  /// Initial choice for new consent; saved per-book choices take precedence.
  final String defaultProviderId;

  /// All sources, including unconfigured entries that remain visible disabled.
  final List<IllustrationProviderOption> providers;

  /// Whether any source is configured; admission also requires [enabled].
  bool get hasAvailableProvider =>
      providers.any((provider) => provider.available);

  /// Reads server configuration before exposing generation controls.
  factory IllustrationConfiguration.fromJson(Map<String, dynamic> json) {
    return IllustrationConfiguration(
      enabled: json['enabled'] as bool,
      defaultProviderId: json['defaultProviderId'] as String,
      providers: List.unmodifiable(
        (json['providers'] as List<dynamic>).map(
          (value) => IllustrationProviderOption.fromJson(
            (value as Map).cast<String, dynamic>(),
          ),
        ),
      ),
    );
  }
}
