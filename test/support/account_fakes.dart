import 'package:reader/account/api.dart';

/// Deferred owned snapshots expose account changes during outstanding reads.
class FakeAccountApi implements AccountApi {
  @override
  bool configured = true;

  /// Counts read-only requests separately from feature registration/generation.
  int requests = 0;

  /// May hold or fail a response to exercise visible loading and retry states.
  Future<AccountUsage> Function() response = () async => testAccountUsage();

  @override
  Future<AccountUsage> usage() {
    requests++;
    return response();
  }
}

/// October UTC snapshot; nullable credits distinguish unactivated accounts.
AccountUsage testAccountUsage({
  int? illustrationCreditsRemaining,
  int? illustrationCreditsReserved,
}) => AccountUsage(
  asOf: DateTime.utc(2026, 10, 7),
  narrationEnabled: false,
  narrationMonthlyLimit: 500000,
  narrationRemaining: 123456,
  narrationResetAt: DateTime.utc(2026, 11),
  illustrationsEnabled: false,
  illustrationCreditsRemaining: illustrationCreditsRemaining,
  illustrationCreditsReserved: illustrationCreditsReserved,
);
