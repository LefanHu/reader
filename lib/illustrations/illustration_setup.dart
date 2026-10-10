// DTO fields mirror the documented REST contract in this file.
// ignore_for_file: public_member_api_docs

/// Book registration result shown before prose is uploaded.
class IllustrationSetup {
  const IllustrationSetup({
    required this.cloudBookId,
    required this.suggestedStyle,
    required this.alternativeStyles,
    required this.estimatedCredits,
  });

  final String cloudBookId;
  final String suggestedStyle;
  final List<String> alternativeStyles;
  final int estimatedCredits;
}
