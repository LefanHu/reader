import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/account/http_account_api.dart';
import 'package:reader/identity/cloud_failure_kind.dart';
import 'package:reader/identity/cloud_identity_exception.dart';
import 'package:reader/identity/cloud_service_exception.dart';
import 'package:reader/identity/firebase_cloud_identity.dart';
import 'package:reader/identity/google_identity_provider.dart';
import 'package:reader/narration/http_narration_api.dart';

import 'support/dev_api_client.dart';
import 'support/dev_api_environment.dart';
import 'support/dev_api_identity.dart';

class _Google extends Fake implements GoogleIdentityProvider {
  final List<String> events;
  _Google(this.events);
  bool cancelled = false, failLogout = false;
  @override
  Future<String> idToken() async {
    events.add('google');
    if (cancelled) {
      throw const CloudIdentityException(
        CloudFailureKind.cancelled,
        'Cancelled',
      );
    }
    return 'native-token';
  }

  @override
  Future<void> signOut() async {
    events.add('google-out');
    if (failLogout) throw StateError('Native logout failed');
  }
}

class _Credential extends Fake implements UserCredential {}

class _User extends Fake implements User {
  final List<String> events;
  final String idToken;
  _User(this.events, {this.idToken = 'firebase-token'});
  bool rejectReauth = false;
  @override
  String get email => 'reader@example.test';
  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async => idToken;
  @override
  Future<UserCredential> reauthenticateWithCredential(
    AuthCredential credential,
  ) async {
    events.add('reauth');
    expect(credential.providerId, 'google.com');
    if (rejectReauth) throw StateError('Different account');
    return _Credential();
  }

  @override
  Future<void> delete() async {
    events.add('delete-user');
  }
}

class _Auth extends Fake implements FirebaseAuth {
  final List<String> events;
  _Auth(this.events);
  @override
  User? currentUser;
  @override
  Future<UserCredential> signInWithCredential(AuthCredential credential) async {
    events.add('firebase');
    expect(credential.providerId, 'google.com');
    expect((credential as OAuthCredential).idToken, 'native-token');
    currentUser = _User(events);
    return _Credential();
  }

  @override
  Future<void> signOut() async {
    events.add('firebase-out');
    currentUser = null;
  }
}

void main() {
  late List<String> events;
  late _Auth auth;
  late _Google google;
  late FirebaseCloudIdentity identity;
  setUp(() {
    events = [];
    auth = _Auth(events);
    google = _Google(events);
    identity = FirebaseCloudIdentity(
      auth: auth,
      google: google,
      configured: true,
      initialize: () async {
        events.add('initialize');
      },
      appCheckToken: () async {
        events.add('attest');
        return 'app-token';
      },
    );
  });

  /// Builds a Firebase identity whose requests carry dev-minted [tokens],
  /// sending [appCheckToken] in place of the minted one when given.
  FirebaseCloudIdentity devIdentity(
    DevApiTokens tokens, {
    String? appCheckToken,
  }) {
    auth.currentUser = _User(events, idToken: tokens.idToken);
    return FirebaseCloudIdentity(
      auth: auth,
      google: google,
      configured: true,
      initialize: () async {
        events.add('initialize');
      },
      appCheckToken: () async => appCheckToken ?? tokens.appCheckToken,
    );
  }

  test('core-only Google sign-in exchanges identity without attestation or feature requests', () async {
    await identity.signIn();
    expect(events, ['initialize', 'google', 'firebase']);
    expect(identity.email, 'reader@example.test');
    events.clear();
    expect(await identity.hasSession(), true);
    expect(events, ['initialize']);
    await identity.signIn();
    expect(events.where((event) => event == 'google'), isEmpty);
  });
  test('cancelled Google authentication creates no Firebase session', () async {
    google.cancelled = true;
    await expectLater(
      identity.signIn(),
      throwsA(
        isA<CloudIdentityException>().having(
          (e) => e.kind,
          'kind',
          CloudFailureKind.cancelled,
        ),
      ),
    );
    expect(auth.currentUser, isNull);
    expect(events, ['initialize', 'google']);
  });
  test('noninteractive feature retries cannot sign in and require attestation only with a session', () async {
    await expectLater(
      identity.authorizationHeaders(interactive: false),
      throwsA(isA<CloudIdentityException>()),
    );
    expect(events, ['initialize']);
    auth.currentUser = _User(events);
    expect(await identity.authorizationHeaders(interactive: false), {
      'authorization': 'Bearer firebase-token',
      'x-firebase-appcheck': 'app-token',
      'content-type': 'application/json',
    });
    expect(events, ['initialize', 'initialize', 'attest']);
  });
  test(
    'Firebase logout completes even when native Google logout fails',
    () async {
      auth.currentUser = _User(events);
      google.failLogout = true;
      await expectLater(identity.signOut(), throwsStateError);
      expect(events, ['google-out', 'firebase-out']);
      expect(auth.currentUser, isNull);
    },
  );
  test('account deletion verifies the same user before purging data and deleting Firebase identity', () async {
    final tokens = await (await DevApiIdentity.disposable()).tokens();
    final client = DevApiClient.create();
    final api = HttpAccountApi(
      identity: devIdentity(tokens),
      baseUri: DevApiEnvironment.instance.baseUri,
      client: client,
    );
    final hold = client.hold(
      (r) => r.method == 'DELETE' && r.url.path == '/api/account',
    );
    unawaited(
      hold.started.then((_) {
        events.add('purge');
        hold.release();
      }),
    );
    await api.deleteAccount();
    expect(
      events.where(
        (event) =>
            ['reauth', 'purge', 'delete-user', 'google-out'].contains(event),
      ),
      ['reauth', 'purge', 'delete-user', 'google-out'],
    );
    expect(client.exchanges.map((e) => (e.method, e.path, e.status)), [
      ('DELETE', '/api/account', 204),
    ]);
  }, timeout: devApiTimeout);
  test(
    'different-account reauthentication prevents destructive server requests',
    () async {
      auth.currentUser = _User(events)..rejectReauth = true;
      final client = DevApiClient.create();
      final api = HttpAccountApi(
        identity: identity,
        baseUri: DevApiEnvironment.instance.baseUri,
        client: client,
      );
      await expectLater(api.deleteAccount(), throwsStateError);
      expect(events, ['initialize', 'google', 'reauth']);
      expect(client.exchanges, isEmpty);
    },
  );
  test('failed server purge preserves the Firebase user for retry', () async {
    final tokens = await (await DevApiIdentity.shared()).tokens();
    final api = HttpAccountApi(
      identity: devIdentity(tokens, appCheckToken: 'dev-api-test-rejected'),
      baseUri: DevApiEnvironment.instance.baseUri,
      client: DevApiClient.create(),
    );
    await expectLater(
      api.deleteAccount(),
      throwsA(
        isA<CloudServiceException>().having(
          (error) => error.statusCode,
          'statusCode',
          401,
        ),
      ),
    );
    expect(events, isNot(contains('delete-user')));
    expect(auth.currentUser, isNotNull);
  }, timeout: devApiTimeout);
  test(
    'missing account deletion endpoint preserves the Firebase user',
    () async {
      final tokens = await (await DevApiIdentity.shared()).tokens();
      final identity = devIdentity(tokens);
      final client = DevApiClient.create();
      final baseUri = DevApiEnvironment.instance.baseUri;
      final api = HttpAccountApi(
        identity: identity,
        baseUri: baseUri,
        client: client,
      );
      final narration = HttpNarrationApi(
        identity: identity,
        baseUri: baseUri,
        client: client,
      );
      client.missingRoute(
        (r) => r.method == 'DELETE' && r.url.path == '/api/account',
      );
      await expectLater(
        api.deleteAccount(),
        throwsA(
          isA<CloudServiceException>().having(
            (error) => error.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
      expect(events, isNot(contains('delete-user')));
      expect(auth.currentUser, isNotNull);
      final bookId = 'f' * 64;
      await narration.deleteBook(bookId);
      expect(client.exchanges.map((e) => e.path), [
        '/api/account',
        '/api/narration/books/$bookId',
      ]);
      expect(client.exchanges.map((e) => e.status), [404, 204]);
      expect(events, isNot(contains('delete-user')));
    },
    timeout: devApiTimeout,
  );
  test('native selector failure cannot reverse completed Firebase account deletion', () async {
    auth.currentUser = _User(events);
    google.failLogout = true;
    await identity.deleteAccount();
    expect(events, ['initialize', 'delete-user', 'google-out']);
  });
}
