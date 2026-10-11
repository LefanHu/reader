// DTO fields mirror the documented REST contract in this file.
// ignore_for_file: public_member_api_docs

import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../catalog/catalog_book.dart';
import '../identity/cloud_book_fingerprint.dart';
import '../identity/cloud_http_client.dart';
import '../identity/cloud_identity.dart';
import 'api.dart';
import 'chapter_text_index.dart';
import 'illustration_exception.dart';
import 'illustration_job_result.dart';
import 'illustration_profile.dart';
import 'illustration_scene.dart';
import 'illustration_setup.dart';
import 'scene_anchor.dart';
import 'unlocked_illustration.dart';

/// Cloud Run REST client with injected HTTP and identity dependencies.
class HttpIllustrationApi implements IllustrationApi {
  HttpIllustrationApi({
    required CloudIdentity identity,
    http.Client? client,
    Uri? baseUri,
  }) : _http = CloudHttpClient(
         identity: identity,
         client: client,
         baseUri: baseUri,
       );

  final CloudHttpClient _http;

  /// Server-issued book, job and scene identities are 40 lowercase hex digits.
  static final _cloudId = RegExp(r'^[a-f0-9]{40}$');

  @override
  bool get configured => _http.configured;

  @override
  Future<IllustrationSetup> registerBook(
    CatalogBook book, {
    required int chapterCount,
  }) async {
    final keyJson = await _json('GET', '/v1/fingerprint-key');
    final encodedKey = keyJson['key'] as String?;
    if (encodedKey == null) {
      throw const IllustrationException('The server returned no book key.');
    }
    final fingerprint = cloudBookFingerprint(book.hash, encodedKey);
    final json = await _json(
      'POST',
      '/v1/books',
      body: {
        'fingerprint': fingerprint,
        'title': book.title,
        'authors': book.authors,
        'language': book.language,
        'chapterCount': chapterCount,
      },
    );
    return IllustrationSetup(
      cloudBookId: _id(json['id']),
      suggestedStyle: json['suggestedStyle'] as String,
      alternativeStyles:
          (json['alternativeStyles'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList(),
      estimatedCredits: (json['estimatedCredits'] as num?)?.round() ?? 0,
    );
  }

  @override
  Future<void> confirmProfile(IllustrationProfile profile) async {
    await _json(
      'PUT',
      '/v1/books/${_id(profile.cloudBookId)}/profile',
      body: {
        'style': profile.style,
        'density': profile.density,
        'styleVersion': profile.styleVersion,
        'analysisVersion': profile.analysisVersion,
      },
    );
  }

  @override
  Future<String> createChapterJob({
    required IllustrationProfile profile,
    required ChapterTextIndex chapter,
  }) async {
    final response = await _json(
      'POST',
      '/v1/books/${_id(profile.cloudBookId)}/chapters/'
          '${chapter.spineOrdinal}/jobs',
      body: {
        'href': chapter.href,
        'title': chapter.title,
        'language': chapter.language,
        'styleVersion': profile.styleVersion,
        'analysisVersion': profile.analysisVersion,
        'density': profile.density,
        'paragraphs': chapter.paragraphs
            .map(
              (paragraph) => {
                'id': paragraph.id,
                'text': paragraph.text,
                'cssSelector': paragraph.cssSelector,
                'ordinal': paragraph.ordinal,
                'progression': paragraph.progression,
              },
            )
            .toList(),
      },
    );
    return _id(response['id']);
  }

  @override
  Future<IllustrationJobResult> getJob(String jobId) async {
    final json = await _json('GET', '/v1/jobs/${_id(jobId)}');
    final scenes = (json['scenes'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) {
          final value = item.cast<String, dynamic>();
          return IllustrationScene(
            id: _id(value['id']),
            jobId: jobId,
            anchor: SceneAnchor.fromJson(
              (value['anchor'] as Map).cast<String, dynamic>(),
            ),
            state: switch (value['status'] as String? ?? 'queued') {
              'ready_locked' => IllustrationSceneState.readyLocked,
              'generating' => IllustrationSceneState.generating,
              'regenerating' => IllustrationSceneState.generating,
              'skipped_safety' => IllustrationSceneState.skippedSafety,
              'failed' => IllustrationSceneState.failed,
              _ => IllustrationSceneState.queued,
            },
            failureCategory: value['failureCategory'] as String?,
          );
        })
        .toList();
    return IllustrationJobResult(
      id: jobId,
      status: json['status'] as String? ?? 'queued',
      scenes: scenes,
      failureCategory: json['failureCategory'] as String?,
    );
  }

  @override
  Future<UnlockedIllustration> unlockScene(String sceneId) async {
    final json = await _json('POST', '/v1/scenes/${_id(sceneId)}/unlock');
    final image = await _bytes(Uri.parse(json['imageUrl'] as String));
    final thumbnail = await _bytes(Uri.parse(json['thumbnailUrl'] as String));
    return UnlockedIllustration(
      image: image,
      thumbnail: thumbnail,
      altText: json['altText'] as String? ?? 'Generated scene illustration',
      caption: json['caption'] as String? ?? '',
      generationVersion: (json['generationVersion'] as num?)?.round() ?? 1,
    );
  }

  @override
  Future<void> regenerateScene(String sceneId) =>
      _json('POST', '/v1/scenes/${_id(sceneId)}/regenerate');

  @override
  Future<void> deleteScene(String sceneId) =>
      _json('DELETE', '/v1/scenes/${_id(sceneId)}');

  @override
  Future<void> deleteBook(String cloudBookId, {bool interactive = true}) async {
    // The server can never hold an invalid ID; dropping it ends outbox retries.
    if (!_cloudId.hasMatch(cloudBookId)) return;
    // A completed previous delete is success, including crash/retry recovery.
    await _http.json(
      'DELETE',
      '/v1/books/$cloudBookId',
      interactive: interactive,
      missingIsSuccess: true,
    );
  }

  String _id(Object? value) {
    if (value is String && _cloudId.hasMatch(value)) return value;
    throw const FormatException('Invalid illustration identity.');
  }

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool interactive = true,
  }) => _http.json(
    method,
    path,
    body: body,
    interactive: interactive,
    maxBytes: 1024 * 1024,
  );

  Future<Uint8List> _bytes(Uri uri) =>
      _http.download(uri, maxBytes: 16 * 1024 * 1024);
}
