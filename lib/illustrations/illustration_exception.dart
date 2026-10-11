// DTO fields mirror the documented REST contract in this file.
// ignore_for_file: public_member_api_docs

/// Recoverable configuration, authentication, or server failure.
class IllustrationException implements Exception {
  const IllustrationException(this.message);
  final String message;
  @override
  String toString() => message;
}
