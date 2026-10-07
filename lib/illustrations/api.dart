import '../cloud_identity.dart';
// DTO fields mirror the documented REST contract in this file.
// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models.dart';
import 'models.dart';

/// Recoverable configuration, authentication, or server failure.
class IllustrationException implements Exception {
  const IllustrationException(this.message, {this.statusCode});
  final String message;

  /// Optional HTTP status for idempotent privacy retries.
  final int? statusCode;
  @override
  String toString() => message;
}

/// Book registration result shown before prose is uploaded.
class IllustrationSetup {
  const IllustrationSetup({
    required this.cloudBookId,
    required this.suggestedStyle,
    required this.alternativeStyles,
    required this.estimatedCredits,
  });

  final String cloudBookId;
  final String suggestedStyle;
  final List<String> alternativeStyles;
  final int estimatedCredits;
}

/// Current server state for an idempotent chapter generation job.
class IllustrationJobResult {
  const IllustrationJobResult({
    required this.id,
    required this.status,
    required this.scenes,
    this.failureCategory,
  });

  final String id;
  final String status;
  final List<IllustrationScene> scenes;
  final String? failureCategory;
}

/// Released metadata and bytes, returned only after the local spoiler gate.
class UnlockedIllustration {
  const UnlockedIllustration({
    required this.image,
    required this.thumbnail,
    required this.altText,
    required this.caption,
    required this.generationVersion,
  });

  final Uint8List image;
  final Uint8List thumbnail;
  final String altText;
  final String caption;
  final int generationVersion;
}

/// Authentication boundary supplying Firebase ID and App Check credentials.
abstract interface class IllustrationIdentity {
  bool get configured;

  /// Checks existing identity without opening a sign-in prompt.
  Future<bool> hasSession();
  Future<void> signInWithApple();
  Future<Map<String, String>> authorizationHeaders({bool interactive = true});
  Future<void> signOut();
  Future<void> deleteAccount();
}

/// Illustration identity stays iOS-only while sharing lazy cloud initialization.
class FirebaseIllustrationIdentity extends FirebaseCloudIdentity {
  @override
  bool get configured =>
      defaultTargetPlatform == TargetPlatform.iOS && super.configured;
}

/// Authenticated API used by the reader; implementations never receive EPUBs.
abstract interface class IllustrationApi {
  /// User-triggered identity preparation before retrying old privacy requests.
  Future<void> signIn();
  bool get configured;

  /// Checks existing identity without opening a sign-in prompt.
  Future<bool> hasSession();
  Future<IllustrationSetup> registerBook(
    CatalogBook book, {
    required int chapterCount,
  });
  Future<void> confirmProfile(IllustrationProfile profile);
  Future<String> createChapterJob({
    required IllustrationProfile profile,
    required ChapterTextIndex chapter,
  });
  Future<IllustrationJobResult> getJob(String jobId);
  Future<UnlockedIllustration> unlockScene(String sceneId);
  Future<void> regenerateScene(String sceneId);
  Future<void> deleteScene(String sceneId);
  Future<void> deleteBook(String cloudBookId, {bool interactive = true});
  Future<void> signOut();
  Future<void> deleteAccount();
}

/// Cloud Run REST client with injected HTTP and identity dependencies.
class HttpIllustrationApi implements IllustrationApi {
  HttpIllustrationApi({
    required this.identity,
    http.Client? client,
    Uri? baseUri,
  }) : client = client ?? http.Client(),
       baseUri =
           baseUri ??
           Uri.parse(const String.fromEnvironment('ILLUSTRATION_API_BASE_URL'));

  final IllustrationIdentity identity;
  final http.Client client;
  final Uri baseUri;

  @override
  bool get configured => identity.configured && baseUri.hasScheme;

  @override
  Future<bool> hasSession() => identity.hasSession();

  @override
  Future<void> signIn() => identity.signInWithApple();

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
    final fingerprint = Hmac(
      sha256,
      base64Decode(encodedKey),
    ).convert(utf8.encode(book.hash)).toString();
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
      cloudBookId: json['id'] as String,
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
      '/v1/books/${profile.cloudBookId}/profile',
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
      '/v1/books/${profile.cloudBookId}/chapters/'
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
    return response['id'] as String;
  }

  @override
  Future<IllustrationJobResult> getJob(String jobId) async {
    final json = await _json('GET', '/v1/jobs/$jobId');
    final scenes = (json['scenes'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) {
          final value = item.cast<String, dynamic>();
          return IllustrationScene(
            id: value['id'] as String,
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
    final json = await _json('POST', '/v1/scenes/$sceneId/unlock');
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
      _empty('POST', '/v1/scenes/$sceneId/regenerate');

  @override
  Future<void> deleteScene(String sceneId) =>
      _empty('DELETE', '/v1/scenes/$sceneId');

  @override
  Future<void> deleteBook(String cloudBookId, {bool interactive = true}) async {
    try {
      await _json('DELETE', '/v1/books/$cloudBookId', interactive: interactive);
    } on IllustrationException catch (error) {
      // A completed previous delete is success, including crash/retry recovery.
      if (error.statusCode != 404) rethrow;
    }
  }

  @override
  Future<void> signOut() => identity.signOut();

  @override
  Future<void> deleteAccount() async {
    await _empty('DELETE', '/v1/account');
    await identity.deleteAccount();
  }

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool interactive = true,
  }) async {
    if (!configured) {
      throw const IllustrationException(
        'Illustrations are not configured in this build.',
      );
    }
    final headers = await identity.authorizationHeaders(
      interactive: interactive,
    );
    final request = http.Request(method, baseUri.resolve(path))
      ..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    final streamed = await client.send(request);
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String message = 'Illustration service error (${response.statusCode}).';
      try {
        message =
            (jsonDecode(response.body) as Map)['error'] as String? ?? message;
      } on Object {
        // Keep the non-sensitive generic response for malformed server errors.
      }
      throw IllustrationException(message, statusCode: response.statusCode);
    }
    if (response.body.isEmpty) return {};
    return (jsonDecode(response.body) as Map).cast<String, dynamic>();
  }

  Future<void> _empty(String method, String path) async {
    await _json(method, path);
  }

  Future<Uint8List> _bytes(Uri uri) async {
    final response = await client.get(uri);
    if (response.statusCode != 200) {
      throw const IllustrationException('Could not download the illustration.');
    }
    return response.bodyBytes;
  }
}
