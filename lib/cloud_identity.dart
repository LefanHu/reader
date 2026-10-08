import 'dart:io';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

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

/// Recoverable identity error; cancellation is a normal user decision.
class CloudIdentityException implements Exception {
  /// Safe messages contain no provider tokens or credential responses.
  const CloudIdentityException(this.message, {this.cancelled = false});

  /// User-facing reason, without raw native authentication details.
  final String message;

  /// Callers dismiss cancelled authentication silently.
  final bool cancelled;
  @override
  String toString() => message;
}

/// Injectable native Google boundary; only identity scopes are requested.
abstract interface class GoogleIdentityProvider {
  /// Returns a fresh ID token after an explicit native authentication action.
  Future<String> idToken();

  /// Clears the native account selection independently of Firebase logout.
  Future<void> signOut();
}

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

/// Lazy Firebase identity shared by library, narration and illustrations on
/// supported native Apple platforms.
/// Firebase/Auth initialization is independent of App Check so core-only builds
/// can authenticate without a feature endpoint or attestation network access.
class FirebaseCloudIdentity implements CloudIdentity {
  /// Injectable SDK boundaries keep authentication and cleanup tests offline.
  FirebaseCloudIdentity({
    FirebaseAuth? auth,
    GoogleIdentityProvider? google,
    Future<void> Function()? initialize,
    Future<String?> Function()? appCheckToken,
    bool? configured,
  }) : _authOverride = auth,
       _google = google ?? NativeGoogleIdentityProvider(),
       _initializeOverride = initialize,
       _appCheckOverride = appCheckToken,
       _configuredOverride = configured;

  final FirebaseAuth? _authOverride;
  final GoogleIdentityProvider _google;
  final Future<void> Function()? _initializeOverride;
  final Future<String?> Function()? _appCheckOverride;
  final bool? _configuredOverride;
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;

  static String get _apiKey => defaultTargetPlatform == TargetPlatform.macOS
      ? const String.fromEnvironment('FIREBASE_MACOS_API_KEY')
      : const String.fromEnvironment('FIREBASE_API_KEY');
  static String get _appId => defaultTargetPlatform == TargetPlatform.macOS
      ? const String.fromEnvironment('FIREBASE_MACOS_APP_ID')
      : const String.fromEnvironment('FIREBASE_APP_ID');
  static const _messagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const _storageBucket = String.fromEnvironment(
    'FIREBASE_STORAGE_BUCKET',
  );
  static const _appCheckDebug = bool.fromEnvironment(
    'FIREBASE_APP_CHECK_DEBUG',
  );
  static Future<void>? _initializing, _checking;

  @override
  bool get configured =>
      _configuredOverride ??
      (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.iOS ||
              defaultTargetPlatform == TargetPlatform.macOS) &&
          _apiKey.isNotEmpty &&
          _appId.isNotEmpty &&
          _messagingSenderId.isNotEmpty &&
          _projectId.isNotEmpty &&
          NativeGoogleIdentityProvider.configured);

  @override
  String? get email => _authOverride != null || Firebase.apps.isNotEmpty
      ? _auth.currentUser?.email
      : null;

  Future<void> _initialize() async {
    if (!configured) {
      throw const CloudIdentityException(
        'Google sign-in is not configured in this build.',
      );
    }
    if (_initializeOverride != null) {
      await _initializeOverride();
      return;
    }
    try {
      await (_initializing ??= () async {
        if (Firebase.apps.isEmpty) {
          await Firebase.initializeApp(
            options: FirebaseOptions(
              apiKey: _apiKey,
              appId: _appId,
              messagingSenderId: _messagingSenderId,
              projectId: _projectId,
              storageBucket: _storageBucket.isEmpty ? null : _storageBucket,
            ),
          );
        }
      }());
    } on Object {
      _initializing = null;
      rethrow;
    }
  }

  Future<String?> _appCheckToken() async {
    if (_appCheckOverride != null) return _appCheckOverride();
    // App Attest needs macOS 14+. Basic Google sign-in and local reading work
    // on older systems; protected feature requests must fail closed there.
    if (Platform.isMacOS &&
        (int.tryParse(
                  RegExp(r'Version (\d+)')
                          .firstMatch(Platform.operatingSystemVersion)
                          ?.group(1) ??
                      '',
                ) ??
                0) <
            14) {
      throw const CloudIdentityException(
        'Cloud generation requires macOS 14 or later.',
      );
    }
    try {
      await (_checking ??= FirebaseAppCheck.instance.activate(
        providerApple: kDebugMode && _appCheckDebug
            ? const AppleDebugProvider()
            : defaultTargetPlatform == TargetPlatform.macOS
            ? const AppleAppAttestProvider()
            : const AppleAppAttestWithDeviceCheckFallbackProvider(),
      ));
    } on Object {
      _checking = null;
      rethrow;
    }
    return FirebaseAppCheck.instance.getToken();
  }

  @override
  Future<bool> hasSession() async {
    if (!configured) return false;
    await _initialize();
    return _auth.currentUser != null;
  }

  Future<AuthCredential> _credential() async =>
      GoogleAuthProvider.credential(idToken: await _google.idToken());

  @override
  Future<void> signIn() async {
    await _initialize();
    if (_auth.currentUser == null) {
      await _auth.signInWithCredential(await _credential());
    }
  }

  @override
  Future<void> reauthenticate() async {
    await _initialize();
    final user = _auth.currentUser;
    if (user == null) {
      throw const CloudIdentityException(
        'Sign in before deleting your cloud account.',
      );
    }
    // Firebase rejects a credential belonging to a different user, preventing
    // an account-chooser switch from changing which account gets purged.
    await user.reauthenticateWithCredential(await _credential());
  }

  @override
  Future<Map<String, String>> authorizationHeaders({
    bool interactive = true,
  }) async {
    if (interactive) {
      await signIn();
    } else {
      await _initialize();
    }
    final idToken = await _auth.currentUser?.getIdToken();
    if (idToken == null || idToken.isEmpty) {
      throw const CloudIdentityException('Sign in to use cloud features.');
    }
    final appCheck = await _appCheckToken();
    if (appCheck == null || appCheck.isEmpty) {
      throw const CloudIdentityException(
        'Could not attest this app for cloud features.',
      );
    }
    return {
      'authorization': 'Bearer $idToken',
      'x-firebase-appcheck': appCheck,
      'content-type': 'application/json',
    };
  }

  @override
  Future<void> signOut() async {
    // Clear Firebase even if the native SDK cannot clear its account selector.
    try {
      await _google.signOut();
    } finally {
      if (_authOverride != null || Firebase.apps.isNotEmpty) {
        await _auth.signOut();
      }
    }
  }

  @override
  Future<void> deleteAccount() async {
    await _initialize();
    await _auth.currentUser?.delete();
    try {
      await _google.signOut();
    } on Object {
      // Firebase deletion is already terminal. A failed native account-selector
      // cleanup must not prevent local consent/audio cleanup or require retry.
    }
  }
}
