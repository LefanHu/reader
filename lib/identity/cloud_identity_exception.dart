import 'cloud_failure_kind.dart';

/// Recoverable identity error; cancellation is a normal user decision.
class CloudIdentityException implements Exception {
  /// Safe messages contain no provider tokens or credential responses.
  const CloudIdentityException(this.kind, this.message);

  /// Failure category; callers dismiss [CloudFailureKind.cancelled] silently.
  final CloudFailureKind kind;

  /// User-facing reason, without raw native authentication details.
  final String message;

  @override
  String toString() => message;
}
