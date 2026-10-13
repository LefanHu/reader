// DTO fields mirror the documented REST contract in this file.
// ignore_for_file: public_member_api_docs

import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../catalog/catalog_book.dart';
import '../hex_identifiers.dart';
import '../identity/cloud_http_client.dart';
import '../identity/cloud_identity.dart';
import 'api.dart';
import 'chapter_text_index.dart';
import 'illustration_configuration.dart';
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

  @override
  bool get configured => _http.configured;

  @override
  Future<IllustrationConfiguration> getConfiguration() async =>
      IllustrationConfiguration.fromJson(
        await _json('GET', '/api/illustrations/config', interactive: true),
      );

  @override
  Future<IllustrationSetup> registerBook(
    CatalogBook book, {
    required int chapterCount,
  }) async {
    final fingerprint = await _http.bookFingerprint(
      book.hash,
      interactive: true,
    );
    final json = await _json(
      'POST',
      '/api/books',
      interactive: true,
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
      configuration: IllustrationConfiguration.fromJson(
        (json['configuration'] as Map).cast<String, dynamic>(),
      ),
      currentProfile: json['currentProfile'] == null
          ? null
          : _profile(json['currentProfile'], _id(json['id'])),
    );
  }

  @override
  Future<IllustrationProfile> confirmProfile(
    IllustrationProfile profile,
  ) async {
    final json = await _json(
      'PUT',
      '/api/books/${_id(profile.cloudBookId)}/profile',
      interactive: true,
      body: {
        'providerId': profile.providerId,
        'style': profile.style,
        'density': profile.density,
        'expectedRevision': profile.revision,
      },
    );
    return _profile(json, profile.cloudBookId);
  }

  @override
  Future<String> createChapterJob({
    required IllustrationProfile profile,
    required ChapterTextIndex chapter,
  }) async {
    final response = await _json(
      'POST',
      '/api/books/${_id(profile.cloudBookId)}/chapters/'
          '${chapter.spineOrdinal}/jobs',
      // Scheduled ahead of the reader in the background; never prompts.
      interactive: false,
      body: {
        'href': chapter.href,
        'title': chapter.title,
        'language': chapter.language,
        'profileRevision': profile.revision,
        'paragraphs': chapter.paragraphs
            .map(
              (paragraph) => {
                'id': paragraph.id,
                'text': paragraph.text,
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
    final json = await _json(
      'GET',
      '/api/jobs/${_id(jobId)}',
      // Polled by a timer while reading; never prompts.
      interactive: false,
    );
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
              'ready_locked' ||
              'unlocked' => IllustrationSceneState.readyLocked,
              'generating' => IllustrationSceneState.generating,
              'regenerating' => IllustrationSceneState.generating,
              'skipped_safety' => IllustrationSceneState.skippedSafety,
              'failed' => IllustrationSceneState.failed,
              _ => IllustrationSceneState.queued,
            },
            generation: value['generation'] as int,
            regenerating:
                value['status'] == 'regenerating' ||
                value['regenerating'] == true,
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
    final json = await _json(
      'POST',
      '/api/scenes/${_id(sceneId)}/unlock',
      // Art downloads automatically once ready; never prompts.
      interactive: false,
    );
    final imageMimeType = _mime(json['imageMimeType']);
    final thumbnailMimeType = _mime(json['thumbnailMimeType']);
    final thumbnailUsesOriginal = json['thumbnailUsesOriginal'] as bool;
    if (thumbnailUsesOriginal &&
        (json['imageUrl'] != json['thumbnailUrl'] ||
            imageMimeType != thumbnailMimeType)) {
      throw const FormatException('Invalid illustration thumbnail alias.');
    }
    final image = await _bytes(Uri.parse(json['imageUrl'] as String));
    final thumbnail = thumbnailUsesOriginal
        ? image
        : await _bytes(Uri.parse(json['thumbnailUrl'] as String));
    return UnlockedIllustration(
      image: image,
      thumbnail: thumbnail,
      altText: json['altText'] as String? ?? 'Generated scene illustration',
      caption: json['caption'] as String? ?? '',
      generation: json['generation'] as int,
      imageMimeType: imageMimeType,
      thumbnailMimeType: thumbnailMimeType,
      thumbnailUsesOriginal: thumbnailUsesOriginal,
    );
  }

  @override
  Future<void> regenerateScene(String sceneId) => _json(
    'POST',
    '/api/scenes/${_id(sceneId)}/regenerate',
    interactive: true,
  );

  @override
  Future<void> deleteScene(String sceneId) =>
      _json('DELETE', '/api/scenes/${_id(sceneId)}', interactive: true);

  @override
  Future<void> deleteBook(String cloudBookId, {bool interactive = true}) async {
    // The server can never hold an invalid ID; dropping it ends outbox retries.
    if (!cloudIdHex.hasMatch(cloudBookId)) return;
    // A completed previous delete is success, including crash/retry recovery.
    await _http.json(
      'DELETE',
      '/api/books/$cloudBookId',
      interactive: interactive,
      missingIsSuccess: true,
    );
  }

  IllustrationProfile _profile(Object? value, String cloudBookId) =>
      IllustrationProfile.fromJson({
        ...(value as Map).cast<String, dynamic>(),
        'enabled': true,
        'cloudBookId': cloudBookId,
      });

  String _mime(Object? value) {
    if (value == 'image/png' ||
        value == 'image/jpeg' ||
        value == 'image/webp') {
      return value as String;
    }
    throw const FormatException('Invalid illustration image MIME.');
  }

  String _id(Object? value) {
    if (value is String && cloudIdHex.hasMatch(value)) return value;
    throw const FormatException('Invalid illustration identity.');
  }

  /// [interactive] is explicit per route: only user-initiated actions may
  /// present sign-in; background scheduling, polling and downloads never do.
  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    required bool interactive,
    Map<String, dynamic>? body,
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
