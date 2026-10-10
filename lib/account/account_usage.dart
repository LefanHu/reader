/// Server-observed account balances, including units held by pending generation.
class AccountUsage {
  /// Values are validated at the HTTP boundary; null credits mean not activated.
  const AccountUsage({
    required this.asOf,
    required this.narrationEnabled,
    required this.narrationMonthlyLimit,
    required this.narrationRemaining,
    required this.narrationResetAt,
    required this.illustrationsEnabled,
    required this.illustrationCreditsRemaining,
    required this.illustrationCreditsReserved,
  });

  /// UTC observation time; this snapshot is not a locally estimated balance.
  final DateTime asOf;

  /// Independent narration rollout state, not authentication availability.
  final bool narrationEnabled;

  /// Configured monthly UTF-16 input allowance.
  final int narrationMonthlyLimit;

  /// Unspent monthly units after submitted and reserved requests.
  final int narrationRemaining;

  /// First instant of the following UTC month.
  final DateTime narrationResetAt;

  /// Independent illustration rollout state.
  final bool illustrationsEnabled;

  /// Total unspent illustration credits; null means no credit initialization.
  final int? illustrationCreditsRemaining;

  /// Credits held by pending jobs; null accompanies an unactivated balance.
  final int? illustrationCreditsReserved;

  /// Rejects malformed balances rather than showing fabricated allowance.
  factory AccountUsage.fromJson(Map<String, dynamic> json) {
    int integer(String key) {
      final value = json[key];
      if (value is! int || value < 0 || value > 9007199254740991) {
        throw const FormatException('Invalid usage balance.');
      }
      return value;
    }

    bool flag(String key) {
      final value = json[key];
      if (value is! bool) throw const FormatException('Invalid feature state.');
      return value;
    }

    DateTime date(String key) {
      final value = json[key];
      final parsed = value is String && value.endsWith('Z')
          ? DateTime.tryParse(value)
          : null;
      if (parsed == null) {
        throw const FormatException('Invalid usage timestamp.');
      }
      return parsed.toUtc();
    }

    final limit = integer('narrationMonthlyLimit');
    final remaining = integer('narrationRemaining');
    final asOf = date('asOf');
    final reset = date('narrationResetAt');
    final expectedReset = DateTime.utc(asOf.year, asOf.month + 1);
    if (remaining > limit ||
        reset != expectedReset ||
        (json['illustrationCreditsRemaining'] == null) !=
            (json['illustrationCreditsReserved'] == null)) {
      throw const FormatException('Inconsistent usage snapshot.');
    }
    return AccountUsage(
      asOf: asOf,
      narrationEnabled: flag('narrationEnabled'),
      narrationMonthlyLimit: limit,
      narrationRemaining: remaining,
      narrationResetAt: reset,
      illustrationsEnabled: flag('illustrationsEnabled'),
      illustrationCreditsRemaining: json['illustrationCreditsRemaining'] == null
          ? null
          : integer('illustrationCreditsRemaining'),
      illustrationCreditsReserved: json['illustrationCreditsReserved'] == null
          ? null
          : integer('illustrationCreditsReserved'),
    );
  }
}
