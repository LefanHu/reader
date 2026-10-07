import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reader/cloud_identity.dart';
import 'package:reader/narration/api.dart';

class _Google extends Fake implements GoogleIdentityProvider {
  final List<String> events;
  _Google(this.events);
  bool cancelled = false, failLogout = false;
  @override
  Future<String> idToken() async {
    events.add('google');
    if (cancelled) {
      throw const CloudIdentityException('Cancelled', cancelled: true);
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
  _User(this.events);
  bool rejectReauth = false;
  @override
  String get email => 'reader@example.test';
  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async =>
      'firebase-token';
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
          (e) => e.cancelled,
          'cancelled',
          true,
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
    auth.currentUser = _User(events);
    final api = HttpNarrationApi(
      identity: identity,
      baseUri: Uri.parse('https://example.test'),
      client: MockClient((request) async {
        expect(request.url.path, '/v1/account');
        events.add('purge');
        return http.Response('', 204);
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
  });
  test(
    'different-account reauthentication prevents destructive server requests',
    () async {
      auth.currentUser = _User(events)..rejectReauth = true;
      final api = HttpNarrationApi(
        identity: identity,
        baseUri: Uri.parse('https://example.test'),
        client: MockClient((request) async {
          fail('Reauthentication must finish before purging data.');
        }),
      );
      await expectLater(api.deleteAccount(), throwsStateError);
      expect(events, ['initialize', 'google', 'reauth']);
    },
  );
  test('failed server purge preserves the Firebase user for retry', () async {
    auth.currentUser = _User(events);
    final api = HttpNarrationApi(
      identity: identity,
      baseUri: Uri.parse('https://example.test'),
      client: MockClient((request) async => http.Response('', 503)),
    );
    await expectLater(api.deleteAccount(), throwsStateError);
    expect(events, isNot(contains('delete-user')));
    expect(auth.currentUser, isNotNull);
  });
  test('native selector failure cannot reverse completed Firebase account deletion', () async {
    auth.currentUser = _User(events);
    google.failLogout = true;
    await identity.deleteAccount();
    expect(events, ['initialize', 'delete-user', 'google-out']);
  });
}
