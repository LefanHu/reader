import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reader/identity/cloud_failure_kind.dart';
import 'package:reader/identity/cloud_service_exception.dart';
import 'package:reader/illustrations/http_illustration_api.dart';

import 'support/cloud_identity_fake.dart';

final _baseUri = Uri.parse('https://example.test');

HttpIllustrationApi _api(MockClient client) => HttpIllustrationApi(
  identity: FakeCloudIdentity(),
  baseUri: _baseUri,
  client: client,
);

void main() {
  test(
    'cloud book deletion treats already absent data as success without sign-in',
    () async {
      final identity = FakeCloudIdentity();
      final api = HttpIllustrationApi(
        identity: identity,
        baseUri: _baseUri,
        client: MockClient(
          (request) async => http.Response('{"error":"Book not found."}', 404),
        ),
      );
      await api.deleteBook('a' * 40, interactive: false);
      expect(identity.signIns, 0);
    },
  );
  test(
    'failed cloud deletion remains retryable and preserves its HTTP status',
    () async {
      final api = _api(
        MockClient(
          (request) async =>
              http.Response('{"error":"Temporarily unavailable"}', 503),
        ),
      );
      await expectLater(
        api.deleteBook('a' * 40, interactive: false),
        throwsA(
          isA<CloudServiceException>().having(
            (error) => error.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
    },
  );
  test('unlocked scenes never download from plain HTTP URLs', () async {
    final requests = <http.BaseRequest>[];
    final api = _api(
      MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'imageUrl': 'http://x.test/i.webp',
            'thumbnailUrl': 'https://x.test/t.webp',
          }),
          200,
        );
      }),
    );
    await expectLater(
      api.unlockScene('a' * 40),
      throwsA(
        isA<CloudServiceException>().having(
          (error) => error.kind,
          'kind',
          CloudFailureKind.service,
        ),
      ),
    );
    expect(requests.where((request) => request.url.scheme == 'http'), isEmpty);
  });
  test('illustration downloads stop at their byte limit', () async {
    const limit = 16 * 1024 * 1024;
    final api = _api(
      MockClient.streaming((request, body) async {
        if (request.url.host == 'example.test') {
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'imageUrl': 'https://x.test/i.webp',
                  'thumbnailUrl': 'https://x.test/t.webp',
                }),
              ),
            ),
            200,
          );
        }
        return http.StreamedResponse(
          Stream.fromIterable([
            List.filled(limit, 0),
            const [0],
          ]),
          200,
        );
      }),
    );
    await expectLater(
      api.unlockScene('a' * 40),
      throwsA(
        isA<CloudServiceException>().having(
          (error) => error.message,
          'message',
          'Cloud download exceeded its limit.',
        ),
      ),
    );
  });
  test('server scene identities are validated before use', () async {
    final api = _api(
      MockClient(
        (request) async => http.Response(
          jsonEncode({
            'status': 'complete',
            'scenes': [
              {
                'id': '../x',
                'status': 'ready_locked',
                'anchor': <String, dynamic>{},
              },
            ],
          }),
          200,
        ),
      ),
    );
    await expectLater(api.getJob('b' * 40), throwsFormatException);
  });
}
