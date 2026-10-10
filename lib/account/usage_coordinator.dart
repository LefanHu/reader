import 'account_usage.dart';
import 'account_usage_exception.dart';
import 'api.dart';

/// Owns account usage snapshots and fences requests across identity changes.
///
/// The controller retains identity actions and remains the sole notifier. Email
/// and busy callbacks read live identity state; [changed] publishes refresh
/// transitions without coupling request fencing to widgets or catalog storage.
class AccountUsageCoordinator {
  /// Accepts the read-only account boundary without acquiring a cloud session.
  AccountUsageCoordinator({
    required this._api,
    required this._currentEmail,
    required this._accountBusy,
    required this._changed,
  });

  final AccountApi? _api;
  final String? Function() _currentEmail;
  final bool Function() _accountBusy;
  final void Function() _changed;
  int _epoch = 0;
  bool _disposed = false;

  /// Latest server snapshot for the displayed account, never a local estimate.
  AccountUsage? usage;

  /// Suppresses duplicate refreshes without locking local preferences.
  bool loading = false;

  /// Safe display message; a failed refresh clears any previous balance.
  String? error;

  /// Distinguishes offline, attestation, and service failures in Settings.
  AccountUsageFailureKind? failure;

  /// Clears usage and fences pending requests without notifying on its own.
  ///
  /// Identity actions notify after updating their other controller state.
  void invalidate() {
    _epoch++;
    usage = null;
    loading = false;
    error = null;
    failure = null;
  }

  /// Refreshes owned usage without prompting for sign-in or granting consent.
  Future<void> refresh() async {
    if (_disposed || loading || _accountBusy()) return;
    invalidate();
    final api = _api;
    if (_currentEmail() == null || api?.configured != true) {
      _changed();
      return;
    }
    final epoch = _epoch;
    final email = _currentEmail();
    loading = true;
    _changed();
    try {
      final result = await api!.usage();
      if (_disposed || epoch != _epoch || email != _currentEmail()) return;
      usage = result;
    } on AccountUsageException catch (exception) {
      if (_disposed || epoch != _epoch || email != _currentEmail()) return;
      error = exception.message;
      failure = exception.kind;
    } on Object {
      if (_disposed || epoch != _epoch || email != _currentEmail()) return;
      error = 'Usage information could not be refreshed. Try again.';
      failure = AccountUsageFailureKind.service;
    } finally {
      if (!_disposed && epoch == _epoch && email == _currentEmail()) {
        loading = false;
        _changed();
      }
    }
  }

  /// Fences pending completions and future refreshes without clearing UI state.
  ///
  /// The injected API is owned by the dependency graph, not this coordinator.
  void dispose() {
    _disposed = true;
    _epoch++;
  }
}
