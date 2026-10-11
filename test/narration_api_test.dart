import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reader/identity/cloud_identity_exception.dart';
import 'package:reader/narration/http_narration_api.dart';
import 'package:reader/narration/narration_fingerprint.dart';

import 'fixtures/catalog_book.dart';
import 'support/cloud_identity_fake.dart';

/// Keeps attestation failure separate from interactive account authentication.
class _ProtectedIdentity extends FakeCloudIdentity {
  bool rejectAttestation = false;

  @override
  Future<Map<String, String>> authorizationHeaders({
    bool interactive = true,
  }) async {
    if (rejectAttestation) {
      throw const CloudIdentityException('App Check is unavailable.');
    }
    return super.authorizationHeaders(interactive: interactive);
  }
}

void main() {
  test('registration sends only the account-scoped fingerprint with Auth and App Check', () async {
    final identity = _ProtectedIdentity();
    final book = testBook();
    final key = base64Encode(List<int>.filled(32, 7));
    final requests = <http.Request>[];
    final api = HttpNarrationApi(
      identity: identity,
      baseUri: Uri.parse('https://example.test'),
      client: MockClient((request) async {
        requests.add(request);
        expect(request.headers['authorization'], 'Bearer test');
        expect(request.headers['x-firebase-appcheck'], 'test');
        if (request.url.path == '/v1/fingerprint-key') {
          expect(request.method, 'GET');
          return http.Response(jsonEncode({'key': key}), 200);
        }
        expect(request.url.path, '/v1/narration/books');
        expect(request.method, 'POST');
        expect(jsonDecode(request.body), {
          'fingerprint': narrationFingerprint(book.hash, key),
        });
        return http.Response(
          jsonEncode({
            'account': 'account',
            'id': 'a' * 64,
            'remaining': 500000,
          }),
          200,
        );
      }),
    );
    final registration = await api.register(book);
    expect(identity.signIns, 1);
    expect(requests, hasLength(2));
    expect(registration.account, 'account');
    expect(registration.bookId, 'a' * 64);
    expect(registration.remaining, 500000);
  });

  test(
    'cancelled account sign-in prevents narration registration requests',
    () async {
      final identity = _ProtectedIdentity()..cancel = true;
      final requests = <http.Request>[];
      final api = HttpNarrationApi(
        identity: identity,
        baseUri: Uri.parse('https://example.test'),
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        api.register(testBook()),
        throwsA(isA<CloudIdentityException>()),
      );
      expect(identity.signIns, 1);
      expect(requests, isEmpty);
    },
  );

  test(
    'missing App Check prevents registration after account sign-in',
    () async {
      final identity = _ProtectedIdentity()..rejectAttestation = true;
      final requests = <http.Request>[];
      final api = HttpNarrationApi(
        identity: identity,
        baseUri: Uri.parse('https://example.test'),
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        api.register(testBook()),
        throwsA(isA<CloudIdentityException>()),
      );
      expect(identity.signIns, 1);
      expect(requests, isEmpty);
    },
  );
}
