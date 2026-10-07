import 'dart:io';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'illustrations/api.dart'
    show IllustrationIdentity, IllustrationException;

/// Firebase identity initialized entirely from build-time environment values.
///
/// Keeping initialization lazy preserves account-free, offline reading when a
/// build has no Firebase project or the reader never enables a cloud feature.
class FirebaseCloudIdentity implements IllustrationIdentity {
  /// Defers plugin initialization until an explicitly consented cloud action.
  FirebaseCloudIdentity();

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

  static Future<void>? _initializing;

  @override
  bool get configured =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS) &&
      // Production App Attest requires macOS 14; older systems retain all local
      // reading and cached playback, without weakening App Check authentication.
      (!Platform.isMacOS ||
          (int.tryParse(
                    RegExp(r'Version (\d+)')
                            .firstMatch(Platform.operatingSystemVersion)
                            ?.group(1) ??
                        '',
                  ) ??
                  0) >=
              14) &&
      _apiKey.isNotEmpty &&
      _appId.isNotEmpty &&
      _messagingSenderId.isNotEmpty &&
      _projectId.isNotEmpty;

  @override
  Future<bool> hasSession() async {
    if (!configured) return false;
    await _initialize();
    return FirebaseAuth.instance.currentUser != null;
  }

  Future<void> _initialize() {
    if (!configured) {
      throw const IllustrationException(
        'Cloud features are not configured in this build.',
      );
    }
    return _initializing ??= () async {
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
        await FirebaseAppCheck.instance.activate(
          providerApple: kDebugMode && _appCheckDebug
              ? const AppleDebugProvider()
              : defaultTargetPlatform == TargetPlatform.macOS
              ? const AppleAppAttestProvider()
              : const AppleAppAttestWithDeviceCheckFallbackProvider(),
        );
      }
    }();
  }

  @override
  Future<void> signInWithApple() async {
    await _initialize();
    if (FirebaseAuth.instance.currentUser == null) {
      await FirebaseAuth.instance.signInWithProvider(AppleAuthProvider());
    }
  }

  @override
  Future<Map<String, String>> authorizationHeaders({
    bool interactive = true,
  }) async {
    if (interactive) {
      await signInWithApple();
    } else {
      await _initialize();
    }
    final user = FirebaseAuth.instance.currentUser;
    final idToken = await user?.getIdToken();
    final appCheck = await FirebaseAppCheck.instance.getToken();
    if (idToken == null || idToken.isEmpty || appCheck == null) {
      throw const IllustrationException('Could not authorize cloud features.');
    }
    return {
      'authorization': 'Bearer $idToken',
      'x-firebase-appcheck': appCheck,
      'content-type': 'application/json',
    };
  }

  @override
  Future<void> signOut() async {
    if (Firebase.apps.isNotEmpty) await FirebaseAuth.instance.signOut();
  }

  @override
  Future<void> deleteAccount() async {
    await _initialize();
    await FirebaseAuth.instance.currentUser?.delete();
  }
}
