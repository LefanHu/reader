import 'cloud_failure_kind.dart';

/// Recoverable cloud transport failure carrying a safe user-facing message.
class CloudServiceException implements Exception {
  /// [statusCode] is present only for HTTP status failures.
  const CloudServiceException(this.kind, this.message, {this.statusCode});

  /// Failure category used for UI and retry decisions.
  final CloudFailureKind kind;

  /// User-facing reason without credentials or raw server bodies.
  final String message;

  /// HTTP status of a rejected response.
  final int? statusCode;

  @override
  String toString() => message;
}
