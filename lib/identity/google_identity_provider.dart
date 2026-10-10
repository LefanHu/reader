/// Injectable native Google boundary; only identity scopes are requested.
abstract interface class GoogleIdentityProvider {
  /// Returns a fresh ID token after an explicit native authentication action.
  Future<String> idToken();

  /// Clears the native account selection independently of Firebase logout.
  Future<void> signOut();
}
