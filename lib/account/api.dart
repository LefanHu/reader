import 'account_usage.dart';

/// Account reads require an existing session and never grant generation consent.
abstract interface class AccountApi {
  /// Whether public endpoint and native identity configuration are available.
  bool get configured;

  /// Returns a fresh server snapshot without initializing credits or generation.
  Future<AccountUsage> usage();
}
