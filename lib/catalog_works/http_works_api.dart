import 'dart:convert';

import 'package:http/http.dart' as http;

import '../catalog/catalog_book.dart';
import '../identity/cloud_http_client.dart';
import '../identity/cloud_identity.dart';
import 'work_link.dart';
import 'work_text.dart';
import 'works_api.dart';

/// REST transport for the global catalog over the shared bounded client.
class HttpWorksApi implements WorksApi {
  /// Shares the app's connection pool and account identity.
  HttpWorksApi({
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
  static const _linkTimeout = Duration(minutes: 1);

  static final _bookId = RegExp(r'^[0-9a-f]{40}$');

  @override
  Future<WorkSearch> search(String query) async {
    final json = await _http.json(
      'GET',
      '/api/works?q=${Uri.encodeQueryComponent(query)}',
      interactive: true,
    );
    final works = json['works'];
    if (works is! List) {
      throw const FormatException('Invalid catalog search response.');
    }
    return (
      works: [
        for (final item in works.whereType<Map>())
          WorkSummary.fromJson(item.cast<String, dynamic>()),
      ],
      degraded: json['degraded'] == true,
    );
  }

  @override
  Future<WorkLinkResult> link(
    CatalogBook book,
    WorkText text, {
    required String title,
    required String author,
    int? firstPublishYear,
  }) async => _result(
    await _http.json(
      'POST',
      '/api/works/links',
      body: {
        'book': await _book(book, text),
        'title': title,
        'author': author,
        'firstPublishYear': ?firstPublishYear,
        'fingerprints': base64Encode(text.fingerprints),
      },
      timeout: _linkTimeout,
      interactive: true,
    ),
  );

  @override
  Future<WorkLinkResult?> current(CatalogBook book) async {
    final fingerprint = await _http.bookFingerprint(
      book.hash,
      interactive: true,
    );
    final json = await _http.json(
      'GET',
      '/api/works/links/$fingerprint',
      interactive: true,
      missingIsSuccess: true,
    );
    return json.isEmpty ? null : _result(json);
  }

  @override
  Future<void> unlink(CatalogBook book) async {
    final fingerprint = await _http.bookFingerprint(
      book.hash,
      interactive: true,
    );
    await _http.json(
      'DELETE',
      '/api/works/links/$fingerprint',
      interactive: true,
    );
  }

  /// The shared book registration body; the import hash never leaves the device.
  Future<Map<String, dynamic>> _book(CatalogBook book, WorkText text) async => {
    'fingerprint': await _http.bookFingerprint(book.hash, interactive: true),
    'title': book.title,
    'authors': book.authors,
    'language': book.language,
    'chapterCount': text.sectionCount,
  };

  WorkLinkResult _result(Map<String, dynamic> json) {
    final bookId = json['bookId'];
    final score = json['score'];
    final work = json['work'];
    if (bookId is! String ||
        !_bookId.hasMatch(bookId) ||
        score is! num ||
        work is! Map) {
      throw const FormatException('Invalid catalog link response.');
    }
    return (
      cloudBookId: bookId,
      work: WorkSummary.fromJson(work.cast<String, dynamic>()),
      score: score.toDouble(),
    );
  }
}
