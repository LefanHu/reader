/// Classifies cloud identity and transport failures for user-facing handling.
enum CloudFailureKind {
  /// This build lacks cloud configuration.
  notConfigured,

  /// The user dismissed authentication; callers stay silent.
  cancelled,

  /// No authenticated session exists.
  signedOut,

  /// App Check could not attest this installation.
  attestation,

  /// The network was unreachable.
  offline,

  /// The service did not answer in time; callers retry it like [offline].
  timeout,

  /// The cloud service rejected or garbled the request.
  service,
}
