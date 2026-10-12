import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../identity/cloud_book_fingerprint.dart';
import '../identity/cloud_http_client.dart';
import '../identity/cloud_identity.dart';
import '../catalog/catalog_book.dart';
import '../text/narration_chunk.dart';
import 'api.dart';
import 'narration_registration.dart';
import 'source.dart';

/// Authenticated REST client sharing lazy identity with illustrations.
class HttpNarrationApi implements NarrationApi {
  /// Dependencies are injectable so tests and offline reading need no Firebase.
  HttpNarrationApi({required this.identity, http.Client? client, Uri? baseUri})
    : _http = CloudHttpClient(
        identity: identity,
        client: client,
        baseUri: baseUri,
      );

  /// Shared identity permits narration on both native Apple platforms.
  final CloudIdentity identity;

  /// Bounded transport, also used to download short-lived private asset URLs.
  final CloudHttpClient _http;

  @override
  bool get configured => _http.configured;

  // Missing book registrations are idempotent; an absent purge endpoint is not.
  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool missingIsSuccess = false,
  }) =>
      _http.json(method, path, body: body, missingIsSuccess: missingIsSuccess);

  @override
  Future<Map<String, dynamic>> configuration() =>
      _json('GET', '/api/narration/config');
  @override
  Future<NarrationRegistration> register(CatalogBook book) async {
    await identity.signIn();
    final key = await _json('GET', '/api/fingerprint-key');
    // Reuse the privacy-preserving account-specific fingerprint protocol.
    final fingerprint = cloudBookFingerprint(book.hash, key['key'] as String);
    final json = await _json(
      'POST',
      '/api/narration/books',
      body: {'fingerprint': fingerprint},
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
    if (!isCurrent()) throw const NarrationCancelled();
    final job = await _json(
      'POST',
      '/api/narration/books/$bookId/jobs',
      body: {
        'text': chunk.text,
        'digest': chunk.digest,
        'chunkId': chunk.id,
        'voice': voice,
      },
    );
    for (var attempt = 0; attempt < 120 && isCurrent(); attempt++) {
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(job['id'] as String)) {
        throw const FormatException('Invalid narration job identity.');
      }
      final result = await _json('GET', '/api/narration/jobs/${job['id']}');
      if (!isCurrent()) break;
      if (result['status'] == 'ready') {
        final uri = Uri.parse(result['url'] as String);
        if (uri.scheme != 'https') {
          throw StateError('Invalid private audio URL.');
        }
        return _http.download(
          uri,
          maxBytes: 32 * 1024 * 1024,
          isCurrent: isCurrent,
        );
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
      '/api/narration/books/$bookId',
      missingIsSuccess: true,
    );
  }
}
