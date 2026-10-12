import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reader/identity/cloud_failure_kind.dart';
import 'package:reader/identity/cloud_service_exception.dart';
import 'package:reader/illustrations/http_illustration_api.dart';
import 'package:reader/illustrations/illustration_profile.dart';
import 'package:reader/illustrations/illustration_scene.dart';

import 'support/cloud_identity_fake.dart';
import 'support/illustration_image_fixture.dart';

final _baseUri = Uri.parse('https://example.test');

HttpIllustrationApi _api(MockClient client) => HttpIllustrationApi(
  identity: FakeCloudIdentity(),
  baseUri: _baseUri,
  client: client,
);

void main() {
  test(
    'configuration rejects unsupported schemas before exposing sources',
    () async {
      final api = _api(
        MockClient(
          (request) async => http.Response(
            jsonEncode({
              'schemaVersion': 3,
              'enabled': true,
              'defaultProviderId': 'openai',
              'providers': [],
            }),
            200,
          ),
        ),
      );
      await expectLater(api.getConfiguration(), throwsFormatException);
    },
  );

  test(
    'profile confirmation cannot invent a missing authoritative revision',
    () async {
      final api = _api(
        MockClient((request) async {
          expect(jsonDecode(request.body), {
            'schemaVersion': 2,
            'providerId': 'google',
            'style': 'Ink',
            'density': 3,
            'expectedRevision': 0,
            'analysisVersion': 2,
          });
          return http.Response(
            jsonEncode({
              'schemaVersion': 2,
              'providerId': 'google',
              'style': 'Ink',
              'density': 3,
              'analysisVersion': 2,
            }),
            200,
          );
        }),
      );
      await expectLater(
        api.confirmProfile(
          IllustrationProfile(
            enabled: true,
            style: 'Ink',
            density: 3,
            providerId: 'google',
            revision: 0,
            cloudBookId: 'a' * 40,
          ),
        ),
        throwsA(isA<TypeError>()),
      );
    },
  );

  test('original thumbnail alias downloads once and shares bytes', () async {
    var downloads = 0;
    final api = _api(
      MockClient((request) async {
        if (request.url.host == 'example.test') {
          return http.Response(
            jsonEncode({
              'imageUrl': 'https://x.test/original.png',
              'thumbnailUrl': 'https://x.test/original.png',
              'imageMimeType': 'image/png',
              'thumbnailMimeType': 'image/png',
              'thumbnailUsesOriginal': true,
              'generationVersion': 4,
            }),
            200,
          );
        }
        downloads++;
        return http.Response.bytes(illustrationPng(), 200);
      }),
    );
    final unlocked = await api.unlockScene('a' * 40);
    expect(downloads, 1);
    expect(identical(unlocked.image, unlocked.thumbnail), isTrue);
    expect(unlocked.imageMimeType, 'image/png');
    expect(unlocked.generationVersion, 4);
  });

  test('job polling preserves version/failure and server unlock remains locally locked', () async {
    final api = _api(
      MockClient(
        (request) async => http.Response(
          jsonEncode({
            'status': 'complete',
            'scenes': [
              for (final status in [
                'ready_locked',
                'unlocked',
                'regenerating',
                'generating',
              ])
                {
                  'id':
                      (status == 'ready_locked'
                          ? 'a'
                          : status == 'unlocked'
                          ? 'b'
                          : status == 'regenerating'
                          ? 'c'
                          : 'd') *
                      40,
                  'status': status,
                  'generationVersion': 3,
                  if (status == 'unlocked') 'failureCategory': 'provider',
                  'anchor': {
                    'href': 's0',
                    'spineOrdinal': 0,
                    'paragraphId': 'p1',
                    'cssSelector': '',
                    'fallbackProgression': .5,
                  },
                },
            ],
          }),
          200,
        ),
      ),
    );
    final result = await api.getJob('e' * 40);
    expect(
      result.scenes.map((scene) => scene.generationVersion),
      everyElement(3),
    );
    expect(result.scenes[0].state, IllustrationSceneState.readyLocked);
    expect(result.scenes[1].state, IllustrationSceneState.readyLocked);
    expect(result.scenes[1].failureCategory, 'provider');
    expect(result.scenes[2].regenerating, isTrue);
    // A first generation is a placeholder state, not a replacement in progress.
    expect(result.scenes[3].regenerating, isFalse);
    expect(result.scenes[3].state, IllustrationSceneState.generating);
    expect(
      result.scenes.every((scene) => scene.localImagePath == null),
      isTrue,
    );
    expect(
      result.scenes.every((scene) => scene.pendingGenerationVersion == null),
      isTrue,
    );
  });

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
            'imageMimeType': 'image/webp',
            'thumbnailMimeType': 'image/webp',
            'thumbnailUsesOriginal': false,
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
                  'imageMimeType': 'image/webp',
                  'thumbnailMimeType': 'image/webp',
                  'thumbnailUsesOriginal': false,
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
