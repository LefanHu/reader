/// Shared account boundary; basic sign-in requires no feature API or App Check.
abstract interface class CloudIdentity {
  /// Whether this native build contains Firebase and Google OAuth configuration.
  bool get configured;

  /// Cached Firebase account email; never triggers initialization or a prompt.
  String? get email;

  /// Restores an existing session without presenting authentication UI.
  Future<bool> hasSession();

  /// Explicit Google authentication; calling it never consents to prose upload.
  Future<void> signIn();

  /// Verifies the same Firebase user before destructive cloud-account actions.
  Future<void> reauthenticate();

  /// Feature requests additionally require App Check; retries remain noninteractive.
  Future<Map<String, String>> authorizationHeaders({bool interactive = true});

  /// Ends both Firebase and native Google sessions, retaining local books.
  Future<void> signOut();

  /// Removes the Firebase user only after callers have purged feature data.
  Future<void> deleteAccount();
}
