import 'account_usage.dart';

/// Account boundary: usage reads never register or generate content, and
/// [deleteAccount] purges every cloud feature before the Firebase user.
abstract interface class AccountApi {
  /// Whether public endpoint and native identity configuration are available.
  bool get configured;

  /// Returns a fresh server snapshot without initializing credits or generation.
  Future<AccountUsage> usage();

  /// Reauthenticates, purges all cloud data, then deletes the Firebase user.
  Future<void> deleteAccount();
}
