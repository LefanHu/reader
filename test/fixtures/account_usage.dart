import 'package:reader/account/account_usage.dart';

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
