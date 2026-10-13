import 'dart:convert';

import 'package:http/http.dart' as http;

import '../catalog/catalog_book.dart';
import '../hex_identifiers.dart';
import '../identity/cloud_http_client.dart';
import '../identity/cloud_identity.dart';
import 'analysis_protocol.dart';
import 'analysis_result.dart';
import 'analysis_source_models.dart';
import 'analysis_limits.dart';
import 'analysis_model.dart';
import 'api.dart';

/// Authenticated preprocessing REST transport that never prompts for an account.
class HttpBookAnalysisApi implements BookAnalysisApi {
  /// Uses the shared bounded transport and existing account-specific fingerprint.
  HttpBookAnalysisApi({
    required CloudIdentity identity,
    http.Client? client,
    Uri? baseUri,
  }) : _http = CloudHttpClient(
         identity: identity,
         client: client,
         baseUri: baseUri,
       );

  final CloudHttpClient _http;
  static final _pageId = RegExp(
    '^(${AnalysisResultPageKind.values.map((kind) => kind.name).join('|')})-(0|[1-9][0-9]*)\$',
  );
  static const _prefix = '/api/book-analysis';

  @override
  bool get configured => _http.configured;

  @override
  Future<AnalysisConfiguration> getConfiguration() async {
    final configuration = AnalysisConfiguration.fromJson(
      await _http.json(
        'GET',
        '$_prefix/config',
        interactive: false,
        maxBytes: analysisPageMaxBytes,
      ),
    );
    _hex(configuration.accountKey);
    return configuration;
  }

  @override
  Future<AnalysisRegistration> registerBook(
    CatalogBook book, {
    required int sectionCount,
  }) async {
    _ordinal(sectionCount);
    final body = {
      'fingerprint': await _http.bookFingerprint(book.hash, interactive: false),
      'title': book.title,
      'authors': book.authors,
      'language': book.language,
      'chapterCount': sectionCount,
    };
    _bounded(body);
    final registration = AnalysisRegistration.fromJson(
      await _http.json(
        'POST',
        '$_prefix/books',
        body: body,
        interactive: false,
        maxBytes: analysisPageMaxBytes,
      ),
    );
    _book(registration.bookId);
    _hex(registration.accountKey);
    return registration;
  }

  @override
  Future<AnalysisReceipt> admitGeneration(
    AnalysisSourceManifest manifest,
    String cloudBookId,
  ) async {
    _book(cloudBookId);
    if (manifest.model != analysisModel) {
      throw const FormatException('Unsupported analysis generation.');
    }
    _hex(manifest.documentDigest);
    final body = manifest.toAdmissionJson();
    _bounded(body);
    return _receipt(
      await _http.json(
        'POST',
        '$_prefix/books/$cloudBookId/generations',
        body: body,
        interactive: false,
        maxBytes: analysisPageMaxBytes,
      ),
    );
  }

  @override
  Future<void> putManifestPage(
    String generationId,
    int pageOrdinal,
    AnalysisDescriptorPage page,
  ) async {
    _hex(generationId);
    _ordinal(pageOrdinal);
    final body = page.toJson();
    AnalysisDescriptorPage.fromJson(body);
    _bounded(body);
    await _http.json(
      'PUT',
      '$_prefix/generations/$generationId/manifest-pages/$pageOrdinal',
      body: body,
      interactive: false,
      maxBytes: analysisPageMaxBytes,
    );
  }

  @override
  Future<AnalysisReceipt> submitChunk(
    String generationId,
    AnalysisChunkInput chunk,
  ) async {
    _hex(generationId);
    _ordinal(chunk.ordinal);
    final body = chunk.toJson();
    AnalysisChunkInput.fromJson(body);
    _bounded(body);
    return _receipt(
      await _http.json(
        'POST',
        '$_prefix/generations/$generationId/chunks/${chunk.ordinal}',
        body: body,
        interactive: false,
        maxBytes: analysisPageMaxBytes,
      ),
      generationId,
    );
  }

  @override
  Future<AnalysisProgress> getProgress(String generationId) async {
    _hex(generationId);
    final progress = AnalysisProgress.fromJson(
      await _http.json(
        'GET',
        '$_prefix/generations/$generationId',
        interactive: false,
        maxBytes: analysisPageMaxBytes,
      ),
    );
    if (progress.generationId != generationId ||
        progress.processedChunks < 0 ||
        progress.processedChunks > progress.requiredChunks ||
        progress.processedUnits < 0 ||
        progress.processedUnits > progress.requiredUnits) {
      throw const FormatException(
        'Invalid analysis progress identity or coverage.',
      );
    }
    _book(progress.bookId);
    _hex(progress.accountKey);
    _hex(progress.documentDigest);
    if (progress.finalizedRevision != null) _hex(progress.finalizedRevision!);
    if (progress.nextCursor != null) _ordinal(progress.nextCursor!.ordinal);
    final pages = <String>{};
    for (final page in progress.resultPages) {
      _page(page.pageId);
      _hex(page.checksum);
      _ordinal(page.ordinal);
      if (!pages.add(page.pageId) ||
          page.byteLength < 1 ||
          page.byteLength > analysisPageMaxBytes ||
          page.pageId != '${page.kind.name}-${page.ordinal}') {
        throw const FormatException('Invalid analysis result descriptor.');
      }
    }
    return progress;
  }

  @override
  Future<AnalysisReceipt> finalize(String generationId) async {
    _hex(generationId);
    return _receipt(
      await _http.json(
        'POST',
        '$_prefix/generations/$generationId/finalize',
        interactive: false,
        maxBytes: analysisPageMaxBytes,
      ),
      generationId,
    );
  }

  @override
  Future<AnalysisResultPage> getPage(String generationId, String pageId) async {
    _hex(generationId);
    _page(pageId);
    final page = AnalysisResultPage.fromJson(
      await _http.json(
        'GET',
        '$_prefix/generations/$generationId/pages/$pageId',
        interactive: false,
        maxBytes: analysisPageMaxBytes,
      ),
    );
    if (page.generationId != generationId ||
        page.pageId != pageId ||
        page.pageId != '${page.kind.name}-${page.ordinal}') {
      throw const FormatException('Invalid analysis result page identity.');
    }
    return page;
  }

  AnalysisReceipt _receipt(Map<String, dynamic> json, [String? generationId]) {
    final receipt = AnalysisReceipt.fromJson(json);
    _hex(receipt.generationId);
    if (receipt.jobId != null) _hex(receipt.jobId!);
    if (receipt.cursor != null) _ordinal(receipt.cursor!.ordinal);
    if (generationId != null && generationId != receipt.generationId) {
      throw const FormatException('Invalid analysis receipt identity.');
    }
    return receipt;
  }

  void _book(String value) {
    if (!cloudIdHex.hasMatch(value)) {
      throw const FormatException('Invalid cloud book identity.');
    }
  }

  void _hex(String value) {
    if (!sha256Hex.hasMatch(value)) {
      throw const FormatException('Invalid analysis identity.');
    }
  }

  void _page(String value) {
    if (!_pageId.hasMatch(value)) {
      throw const FormatException('Invalid analysis page identity.');
    }
  }

  void _ordinal(int value) {
    if (value < 0) throw const FormatException('Invalid analysis ordinal.');
  }

  void _bounded(Map<String, dynamic> body) {
    if (utf8.encode(jsonEncode(body)).length > analysisPageMaxBytes) {
      throw const FormatException('Oversized analysis request.');
    }
  }
}
