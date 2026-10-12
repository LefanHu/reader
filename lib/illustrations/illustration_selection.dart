// Per-book settings selected explicitly by the reader.
// ignore_for_file: public_member_api_docs

/// Explicit per-book consent/settings result, never a global preference.
class IllustrationSelection {
  /// Proposes settings without scheduling work or committing a reading anchor.
  const IllustrationSelection({required this.style, required this.providerId});

  /// Art direction frozen by the server when subsequent work is admitted.
  final String style;

  /// Catalogue ID only; credentials, models and endpoints are server-owned.
  final String providerId;
}
