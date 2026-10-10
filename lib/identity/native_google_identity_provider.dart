import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'cloud_identity_exception.dart';
import 'google_identity_provider.dart';

/// Google SDK initialization is shared and lazy for the app's single native session.
class NativeGoogleIdentityProvider implements GoogleIdentityProvider {
  static Future<void>? _initializing;
  static String get _clientId => defaultTargetPlatform == TargetPlatform.macOS
      ? const String.fromEnvironment('FIREBASE_GOOGLE_MACOS_CLIENT_ID')
      : const String.fromEnvironment('FIREBASE_GOOGLE_CLIENT_ID');
  static const _serverClientId = String.fromEnvironment(
    'FIREBASE_GOOGLE_SERVER_CLIENT_ID',
  );

  /// Both client IDs are public configuration, never OAuth client secrets.
  static bool get configured =>
      _clientId.isNotEmpty && _serverClientId.isNotEmpty;

  Future<void> _initialize() async {
    try {
      await (_initializing ??= GoogleSignIn.instance.initialize(
        clientId: _clientId,
        serverClientId: _serverClientId,
      ));
    } on Object {
      _initializing = null;
      throw const CloudIdentityException(
        'Google sign-in could not initialize. Try again.',
      );
    }
  }

  @override
  Future<String> idToken() async {
    await _initialize();
    try {
      final account = await GoogleSignIn.instance.authenticate();
      final token = account.authentication.idToken;
      if (token == null || token.isEmpty) {
        throw const CloudIdentityException(
          'Google did not return an identity token.',
        );
      }
      return token;
    } on GoogleSignInException catch (error) {
      throw CloudIdentityException(
        error.code == GoogleSignInExceptionCode.canceled
            ? 'Sign-in cancelled.'
            : 'Google sign-in could not be completed. Try again.',
        cancelled: error.code == GoogleSignInExceptionCode.canceled,
      );
    }
  }

  @override
  Future<void> signOut() async {
    // Do not initialize Google merely to clear a restored Firebase session.
    if (_initializing != null) {
      await _initializing;
      await GoogleSignIn.instance.signOut();
    }
  }
}
