import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:reader/identity/cloud_failure_kind.dart';
import 'package:reader/identity/cloud_identity.dart';
import 'package:reader/identity/cloud_identity_exception.dart';

import 'dev_api_client.dart';
import 'dev_api_environment.dart';

/// Real Firebase ID and App Check tokens for one dev test uid.
class DevApiTokens {
  DevApiTokens({
    required this.uid,
    required this.idToken,
    required this.appCheckToken,
    required this.expiresAt,
  });

  factory DevApiTokens.fromJson(Map<String, dynamic> json) => DevApiTokens(
    uid: json['uid'] as String,
    idToken: json['idToken'] as String,
    appCheckToken: json['appCheckToken'] as String,
    expiresAt: DateTime.fromMillisecondsSinceEpoch(json['expiresAt'] as int),
  );

  final String uid;
  final String idToken;
  final String appCheckToken;

  /// Earliest expiry of the two tokens.
  final DateTime expiresAt;

  Map<String, dynamic> toJson() => {
    'uid': uid,
    'idToken': idToken,
    'appCheckToken': appCheckToken,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
  };
}

/// [CloudIdentity] backed by real dev tokens minted by
/// `backend/scripts/dev-test-identity.ts` (ADC + IAM signBlob).
///
/// Shared uids are cached in `build/dev_api_identity/` across test isolates;
/// each call returns a fresh instance so counters and fault switches never
/// leak between tests. Account deletion writes a permanent server tombstone,
/// so destructive tests use [disposable] uids.
class DevApiIdentity implements CloudIdentity {
  /// [_cache] is false for disposable uids, which are never reused.
  DevApiIdentity._(this._tokens, this._cache);

  /// Signed-in identity for a long-lived test uid. Inside `testWidgets`,
  /// await it through `tester.runAsync`.
  static Future<DevApiIdentity> shared({
    String uid = 'dev-api-test-shared',
  }) async => DevApiIdentity._(await _cachedTokens(uid), true);

  /// Fresh signed-in uid whose server data and Firebase user are deleted,
  /// best-effort, when the current test tears down.
  static Future<DevApiIdentity> disposable() async {
    final suffix = Random.secure()
        .nextInt(1 << 24)
        .toRadixString(16)
        .padLeft(6, '0');
    final uid =
        'dev-api-test-disposable-${DateTime.now().millisecondsSinceEpoch}-'
        '$suffix';
    final identity = DevApiIdentity._(await _mint(uid), false);
    addTearDown(identity._purge);
    return identity;
  }

  static final _memory = <String, DevApiTokens>{};

  DevApiTokens _tokens;
  final bool _cache;
  bool _signedIn = true;

  int signIns = 0, signOuts = 0, reauthentications = 0, deletions = 0;

  /// Sends an invalid App Check token so dev answers with a real 401.
  bool rejectAppCheck = false;

  @override
  bool get configured => true;

  @override
  String? get email => _signedIn ? '${_tokens.uid}@dev-api.test' : null;

  @override
  Future<bool> hasSession() async => email != null;

  @override
  Future<void> signIn() async {
    signIns++;
    _signedIn = true;
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    _signedIn = false;
  }

  @override
  Future<void> reauthenticate() async {
    reauthentications++;
    _tokens = await _mint(_tokens.uid);
    if (_cache) await _store(_tokens);
  }

  @override
  Future<Map<String, String>> authorizationHeaders({
    required bool interactive,
  }) async {
    if (!_signedIn) {
      if (!interactive) {
        throw const CloudIdentityException(
          CloudFailureKind.signedOut,
          'Signed out',
        );
      }
      await signIn();
    }
    return {
      'authorization': 'Bearer ${_tokens.idToken}',
      'x-firebase-appcheck': rejectAppCheck
          ? 'dev-api-test-rejected'
          : _tokens.appCheckToken,
      'content-type': 'application/json',
    };
  }

  /// Signs in as another shared uid, as a native account switch would.
  Future<void> switchAccount(String uid) async {
    _tokens = await _cachedTokens(uid);
    _signedIn = true;
  }

  /// Deletes the real Firebase user, as the native identity does after the
  /// server purge.
  @override
  Future<void> deleteAccount() async {
    deletions++;
    final response = await onRealEventLoop(() async {
      final client = devNetworkClient();
      try {
        return await _identityToolkit(client, 'accounts:delete', {
          'idToken': _tokens.idToken,
        });
      } finally {
        client.close();
      }
    });
    if (response.statusCode != 200) {
      throw StateError('accounts:delete failed (${response.statusCode})');
    }
    _signedIn = false;
  }

  /// Current tokens, for tests that drive a real [CloudIdentity] wrapper.
  Future<DevApiTokens> tokens() async => _tokens;

  Future<void> _purge() => onRealEventLoop(() async {
    final client = devNetworkClient();
    try {
      await client.delete(
        DevApiEnvironment.instance.baseUri.resolve('/api/account'),
        headers: {
          'authorization': 'Bearer ${_tokens.idToken}',
          'x-firebase-appcheck': _tokens.appCheckToken,
        },
      );
    } on Object {
      // Best effort: the test may already have deleted the account.
    }
    try {
      await _identityToolkit(client, 'accounts:delete', {
        'idToken': _tokens.idToken,
      });
    } on Object {
      // Best effort: the Firebase user may already be gone.
    }
    client.close();
  });

  static Future<http.Response> _identityToolkit(
    http.Client client,
    String method,
    Map<String, Object> body,
  ) {
    final environment = DevApiEnvironment.instance;
    return client.post(
      Uri.https('identitytoolkit.googleapis.com', '/v1/$method', {
        'key': environment.apiKey,
      }),
      headers: {
        'content-type': 'application/json',
        'X-Ios-Bundle-Identifier': environment.bundleId,
      },
      body: jsonEncode(body),
    );
  }

  static File _cacheFile(String uid) =>
      File('${Directory.current.path}/build/dev_api_identity/$uid.json');

  /// Reuses tokens with more than ten minutes left; test files run in
  /// parallel isolates, so the disk cache is shared and written atomically.
  static Future<DevApiTokens> _cachedTokens(String uid) =>
      onRealEventLoop(() async {
        final margin = DateTime.now().add(const Duration(minutes: 10));
        final memory = _memory[uid];
        if (memory != null && memory.expiresAt.isAfter(margin)) return memory;
        final file = _cacheFile(uid);
        try {
          final cached = DevApiTokens.fromJson(
            jsonDecode(await file.readAsString()) as Map<String, dynamic>,
          );
          if (cached.uid == uid && cached.expiresAt.isAfter(margin)) {
            return _memory[uid] = cached;
          }
        } on Object {
          // Missing or partial cache: mint below.
        }
        final tokens = await _mint(uid);
        await _store(tokens);
        return tokens;
      });

  static Future<void> _store(DevApiTokens tokens) async {
    _memory[tokens.uid] = tokens;
    final file = _cacheFile(tokens.uid);
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.$pid.${Random.secure().nextInt(1 << 32)}.tmp',
    );
    await temporary.writeAsString(jsonEncode(tokens.toJson()), flush: true);
    await temporary.rename(file.path);
  }

  static Future<DevApiTokens> _mint(String uid) => onRealEventLoop(() async {
    final result = await Process.run('npx', [
      'tsx',
      'scripts/dev-test-identity.ts',
      '--uid',
      uid,
      '--defines',
      '../.dart-defines/dev.json',
    ], workingDirectory: '${Directory.current.path}/backend');
    if (result.exitCode != 0) {
      throw StateError('Dev API identity minting failed: ${result.stderr}');
    }
    return DevApiTokens.fromJson(
      jsonDecode((result.stdout as String).trim()) as Map<String, dynamic>,
    );
  });
}
