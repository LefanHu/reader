// DTO fields mirror the documented REST contract in this file.
// ignore_for_file: public_member_api_docs

/// Recoverable configuration, authentication, or server failure.
class IllustrationException implements Exception {
  const IllustrationException(this.message, {this.statusCode});
  final String message;

  /// Optional HTTP status for idempotent privacy retries.
  final int? statusCode;
  @override
  String toString() => message;
}
