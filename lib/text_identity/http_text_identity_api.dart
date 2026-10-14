import 'dart:convert';

import 'package:http/http.dart' as http;

import '../catalog/catalog_book.dart';
import '../identity/cloud_http_client.dart';
import '../identity/cloud_identity.dart';
import 'paragraph_fingerprints.dart';
import 'text_identity_api.dart';

/// REST transport for content identity over the shared bounded client.
class HttpTextIdentityApi implements TextIdentityApi {
  /// Shares the app's connection pool and account identity.
  HttpTextIdentityApi({
    required CloudIdentity identity,
    http.Client? client,
    Uri? baseUri,
  }) : _http = CloudHttpClient(
         identity: identity,
         client: client,
         baseUri: baseUri,
       );

  final CloudHttpClient _http;

  /// Fingerprints of a long book can take a while on a slow connection.
  static const _timeout = Duration(minutes: 1);

  static final _bookId = RegExp(r'^[0-9a-f]{40}$');
  static final _textId = RegExp(r'^[0-9a-f]{20}$');

  @override
  Future<TextIdentityResult> identify(
    CatalogBook book,
    BookFingerprints fingerprints,
  ) async {
    final json = await _http.json(
      'POST',
      '/api/texts/identify',
      body: {
        // The shared book registration; the import hash never leaves the device.
        'book': {
          'fingerprint': await _http.bookFingerprint(
            book.hash,
            interactive: false,
          ),
          'title': book.title,
          'authors': book.authors,
          'language': book.language,
          'chapterCount': fingerprints.sectionCount,
        },
        'fingerprints': base64Encode(fingerprints.fingerprints),
      },
      timeout: _timeout,
    );
    final bookId = json['bookId'];
    final textId = json['textId'];
    final score = json['score'];
    if (bookId is! String ||
        !_bookId.hasMatch(bookId) ||
        textId is! String ||
        !_textId.hasMatch(textId) ||
        score is! num) {
      throw const FormatException('Invalid text identity response.');
    }
    return (cloudBookId: bookId, textId: textId, score: score.toDouble());
  }
}
