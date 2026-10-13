/// Shared account boundary; basic sign-in requires no feature API or App Check.
abstract interface class CloudIdentity {
  /// Whether this native build contains Firebase and Google OAuth configuration.
  bool get configured;

  /// Cached Firebase account email; never triggers initialization or a prompt.
  String? get email;

  /// Restores an existing session without presenting authentication UI.
  Future<bool> hasSession();

  /// Explicit Google authentication; never enables illustrations or uploads prose.
  Future<void> signIn();

  /// Verifies the same Firebase user before destructive cloud-account actions.
  Future<void> reauthenticate();

  /// Feature requests additionally require App Check. Only user-initiated
  /// requests pass [interactive]; background work must never prompt sign-in.
  Future<Map<String, String>> authorizationHeaders({required bool interactive});

  /// Ends both Firebase and native Google sessions, retaining local books.
  Future<void> signOut();

  /// Removes the Firebase user only after callers have purged feature data.
  Future<void> deleteAccount();
}
