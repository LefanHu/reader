/// Recoverable transport categories used by Settings without exposing credentials.
enum AccountUsageFailureKind {
  /// Network unavailable or request timed out; retry preserves the session.
  offline,

  /// Protected requests could not obtain or verify installation attestation.
  attestation,

  /// Unconfigured endpoint, authentication expiry, or invalid service response.
  service,
}

/// Safe account status failure; never includes raw provider responses or tokens.
class AccountUsageException implements Exception {
  /// Carries a presentation category and a safe explanation.
  const AccountUsageException(this.kind, this.message);

  /// Allows distinct retry/attestation UI.
  final AccountUsageFailureKind kind;

  /// User-facing explanation, excluding credential details.
  final String message;
  @override
  String toString() => message;
}
