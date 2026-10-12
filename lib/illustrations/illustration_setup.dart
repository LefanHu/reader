// DTO fields mirror the documented REST contract in this file.
// ignore_for_file: public_member_api_docs

import 'illustration_configuration.dart';
import 'illustration_profile.dart';

/// Read-only availability or a book registration result, before prose upload.
class IllustrationSetup {
  const IllustrationSetup({
    required this.cloudBookId,
    required this.suggestedStyle,
    required this.alternativeStyles,
    required this.estimatedCredits,
    required this.configuration,
    this.currentProfile,
  });

  /// Absent when rollout is disabled or no source is configured: no cloud book
  /// was registered and no registration credits were initialized.
  final String? cloudBookId;
  final String suggestedStyle;
  final List<String> alternativeStyles;
  final int estimatedCredits;
  final IllustrationConfiguration configuration;
  final IllustrationProfile? currentProfile;
}
