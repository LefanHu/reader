/// Recoverable identity error; cancellation is a normal user decision.
class CloudIdentityException implements Exception {
  /// Safe messages contain no provider tokens or credential responses.
  const CloudIdentityException(this.message, {this.cancelled = false});

  /// User-facing reason, without raw native authentication details.
  final String message;

  /// Callers dismiss cancelled authentication silently.
  final bool cancelled;
  @override
  String toString() => message;
}
