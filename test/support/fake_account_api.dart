import 'package:reader/account/account_usage.dart';
import 'package:reader/account/api.dart';

import '../fixtures/account_usage.dart';

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
