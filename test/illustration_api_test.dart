import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reader/cloud_identity.dart';
import 'package:reader/illustrations/api.dart';

class _Identity implements CloudIdentity {
  int signIns = 0;
  @override
  String? get email => null;
  @override
  Future<void> reauthenticate() async {}
  @override
  bool get configured => true;
  @override
  Future<bool> hasSession() async => true;
  @override
  Future<void> signIn() async {
    signIns++;
  }

  @override
  Future<Map<String, String>> authorizationHeaders({
    bool interactive = true,
  }) async {
    if (interactive) await signIn();
    return {'authorization': 'Bearer test'};
  }

  @override
  Future<void> signOut() async {}
  @override
  Future<void> deleteAccount() async {}
}

void main() {
  test(
    'cloud book deletion treats already absent data as success without sign-in',
    () async {
      final identity = _Identity();
      final api = HttpIllustrationApi(
        identity: identity,
        baseUri: Uri.parse('https://example.test'),
        client: MockClient(
          (request) async => http.Response('{"error":"Book not found."}', 404),
        ),
      );
      await api.deleteBook('old-book', interactive: false);
      expect(identity.signIns, 0);
    },
  );
  test(
    'failed cloud deletion remains retryable and preserves its HTTP status',
    () async {
      final api = HttpIllustrationApi(
        identity: _Identity(),
        baseUri: Uri.parse('https://example.test'),
        client: MockClient(
          (request) async =>
              http.Response('{"error":"Temporarily unavailable"}', 503),
        ),
      );
      await expectLater(
        api.deleteBook('old-book', interactive: false),
        throwsA(
          isA<IllustrationException>().having(
            (error) => error.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
    },
  );
}
