// DTO fields mirror the documented REST contract in this file.
// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models.dart';
import 'models.dart';

/// Recoverable configuration, authentication, or server failure.
class IllustrationException implements Exception {
  const IllustrationException(this.message);
  final String message;
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
  Future<void> signInWithApple();
  Future<Map<String, String>> authorizationHeaders();
  Future<void> signOut();
  Future<void> deleteAccount();
}

/// Firebase identity initialized entirely from build-time environment values.
///
/// Keeping initialization lazy preserves account-free, offline reading when a
/// build has no Firebase project or the reader never enables illustrations.
class FirebaseIllustrationIdentity implements IllustrationIdentity {
  FirebaseIllustrationIdentity();

  static const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const _appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const _messagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const _storageBucket = String.fromEnvironment(
    'FIREBASE_STORAGE_BUCKET',
  );
  static const _appCheckDebug = bool.fromEnvironment(
    'FIREBASE_APP_CHECK_DEBUG',
  );

  Future<void>? _initializing;

  @override
  bool get configured =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      _apiKey.isNotEmpty &&
      _appId.isNotEmpty &&
      _messagingSenderId.isNotEmpty &&
      _projectId.isNotEmpty;

  Future<void> _initialize() {
    if (!configured) {
      throw const IllustrationException(
        'Illustrations are not configured in this build.',
      );
    }
    return _initializing ??= () async {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: FirebaseOptions(
            apiKey: _apiKey,
            appId: _appId,
            messagingSenderId: _messagingSenderId,
            projectId: _projectId,
            storageBucket: _storageBucket.isEmpty ? null : _storageBucket,
          ),
        );
        await FirebaseAppCheck.instance.activate(
          providerApple: kDebugMode && _appCheckDebug
              ? const AppleDebugProvider()
              : const AppleAppAttestWithDeviceCheckFallbackProvider(),
        );
      }
    }();
  }

  @override
  Future<void> signInWithApple() async {
    await _initialize();
    if (FirebaseAuth.instance.currentUser == null) {
      await FirebaseAuth.instance.signInWithProvider(AppleAuthProvider());
    }
  }

  @override
  Future<Map<String, String>> authorizationHeaders() async {
    await signInWithApple();
    final user = FirebaseAuth.instance.currentUser;
    final idToken = await user?.getIdToken();
    final appCheck = await FirebaseAppCheck.instance.getToken();
    if (idToken == null || idToken.isEmpty || appCheck == null) {
      throw const IllustrationException('Could not authorize illustrations.');
    }
    return {
      'authorization': 'Bearer $idToken',
      'x-firebase-appcheck': appCheck,
      'content-type': 'application/json',
    };
  }

  @override
  Future<void> signOut() async {
    if (Firebase.apps.isNotEmpty) await FirebaseAuth.instance.signOut();
  }

  @override
  Future<void> deleteAccount() async {
    await _initialize();
    await FirebaseAuth.instance.currentUser?.delete();
  }
}

/// Authenticated API used by the reader; implementations never receive EPUBs.
abstract interface class IllustrationApi {
  bool get configured;
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
  Future<void> deleteBook(String cloudBookId);
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
  Future<void> deleteBook(String cloudBookId) =>
      _empty('DELETE', '/v1/books/$cloudBookId');

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
  }) async {
    if (!configured) {
      throw const IllustrationException(
        'Illustrations are not configured in this build.',
      );
    }
    final headers = await identity.authorizationHeaders();
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
      throw IllustrationException(message);
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
