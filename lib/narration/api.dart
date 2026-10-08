import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../illustrations/api.dart';
import '../models.dart';
import '../text/narration.dart';
import 'models.dart';

/// Private cloud boundary: no prose leaves the device before registration consent.
abstract interface class NarrationApi {
  /// Whether this build can authenticate to the narration service.
  bool get configured;

  /// Existing-session probe; startup privacy retries never prompt for sign-in.
  Future<bool> hasSession();

  /// Rollout and allowance check uses an existing identity when available.
  Future<Map<String, dynamic>> configuration();

  /// Called only after explicit per-book consent; may open Google sign-in.
  Future<NarrationRegistration> register(CatalogBook book);

  /// Idempotent generation/download of one exact chunk, bounded by the caller.
  Future<Uint8List> audio(
    String bookId,
    NarrationChunk chunk,
    String voice, {
    required bool Function() isCurrent,
  });

  /// Durable privacy retry succeeds for an already-deleted registration.
  Future<void> deleteBook(String bookId);

  /// Ends the shared identity session without deleting local reading data.
  Future<void> signOut();

  /// Purges all cloud features before deleting the authenticated Firebase user.
  Future<void> deleteAccount();
}

/// Authenticated REST client sharing lazy identity with illustrations.
class HttpNarrationApi implements NarrationApi {
  /// Dependencies are injectable so tests and offline reading need no Firebase.
  HttpNarrationApi({required this.identity, http.Client? client, Uri? baseUri})
    : client = client ?? http.Client(),
      baseUri =
          baseUri ??
          Uri.parse(
            const String.fromEnvironment(
              'NARRATION_API_BASE_URL',
              defaultValue: String.fromEnvironment('ILLUSTRATION_API_BASE_URL'),
            ),
          );

  /// Shared identity permits narration on both native Apple platforms.
  final IllustrationIdentity identity;

  /// HTTP boundary, also used to download short-lived private asset URLs.
  final http.Client client;

  /// Deployment URL; provider credentials are never present on the device.
  final Uri baseUri;
  @override
  bool get configured => identity.configured && baseUri.hasScheme;
  @override
  Future<bool> hasSession() => identity.hasSession();

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool missingIsSuccess = false,
  }) async {
    if (!configured) {
      throw StateError('Narration is not configured in this build.');
    }
    final request = http.Request(method, baseUri.resolve(path))
      ..headers.addAll(await identity.authorizationHeaders(interactive: false));
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await client.send(request).timeout(const Duration(seconds: 30)),
    ).timeout(const Duration(seconds: 30));
    // Missing book registrations are idempotent; an absent purge endpoint is not.
    if (response.statusCode == 404 && missingIsSuccess) return {};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Narration service error (${response.statusCode}).');
    }
    return response.body.isEmpty
        ? {}
        : (jsonDecode(response.body) as Map).cast<String, dynamic>();
  }

  @override
  Future<Map<String, dynamic>> configuration() =>
      _json('GET', '/v1/narration/config');
  @override
  Future<NarrationRegistration> register(CatalogBook book) async {
    await identity.signIn();
    final key = await _json('GET', '/v1/fingerprint-key');
    // Reuse the privacy-preserving account-specific fingerprint protocol.
    final fingerprint = narrationFingerprint(book.hash, key['key'] as String);
    final json = await _json(
      'POST',
      '/v1/narration/books',
      body: {'fingerprint': fingerprint, 'consentVersion': 1},
    );
    _bookId(json['id'] as String);
    return NarrationRegistration(
      json['account'] as String,
      json['id'] as String,
      json['remaining'] as int,
    );
  }

  @override
  Future<Uint8List> audio(
    String bookId,
    NarrationChunk chunk,
    String voice, {
    required bool Function() isCurrent,
  }) async {
    _bookId(bookId);
    if (!isCurrent()) throw StateError('Narration session changed.');
    final job = await _json(
      'POST',
      '/v1/narration/books/$bookId/jobs',
      body: {
        'text': chunk.text,
        'digest': chunk.digest,
        'chunkId': chunk.id,
        'chunkVersion': narrationChunkVersion,
        'documentVersion': chunk.start.version,
        'voice': voice,
      },
    );
    for (var attempt = 0; attempt < 120 && isCurrent(); attempt++) {
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(job['id'] as String)) {
        throw const FormatException('Invalid narration job identity.');
      }
      final result = await _json('GET', '/v1/narration/jobs/${job['id']}');
      if (!isCurrent()) break;
      if (result['status'] == 'ready') {
        final uri = Uri.parse(result['url'] as String);
        if (uri.scheme != 'https') {
          throw StateError('Invalid private audio URL.');
        }
        final response = await client
            .send(http.Request('GET', uri))
            .timeout(const Duration(seconds: 30));
        const limit = 32 * 1024 * 1024;
        if (response.statusCode != 200 ||
            (response.contentLength ?? 0) > limit) {
          throw StateError('Could not download narration.');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final part in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          if (!isCurrent() || bytes.length + part.length > limit) {
            throw StateError(
              'Narration download was cancelled or exceeded its limit.',
            );
          }
          bytes.add(part);
        }
        return bytes.takeBytes();
      }
      if (['failed', 'deleted', 'expired'].contains(result['status'])) {
        throw StateError(
          'Narration could not be generated. Retry when connected.',
        );
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw StateError('Narration is buffering. Retry when connected.');
  }

  void _bookId(String value) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
      throw const FormatException('Invalid narration book identity.');
    }
  }

  @override
  Future<void> deleteBook(String bookId) async {
    _bookId(bookId);
    await _json(
      'DELETE',
      '/v1/narration/books/$bookId',
      missingIsSuccess: true,
    );
  }

  @override
  Future<void> signOut() => identity.signOut();

  @override
  Future<void> deleteAccount() async {
    await identity.reauthenticate();
    await _json('DELETE', '/v1/account');
    await identity.deleteAccount();
  }
}

/// Account-scoped fingerprint matches the existing cloud privacy boundary.
String narrationFingerprint(String hash, String key) =>
    Hmac(sha256, base64Decode(key)).convert(utf8.encode(hash)).toString();
