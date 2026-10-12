// Test controls intentionally expose observations and failure barriers.
// ignore_for_file: public_member_api_docs
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:reader/book_analysis/api.dart';
import 'package:reader/book_analysis/analysis_entity.dart';
import 'package:reader/book_analysis/analysis_protocol.dart';
import 'package:reader/book_analysis/analysis_result.dart';
import 'package:reader/book_analysis/analysis_source_models.dart';
import 'package:reader/book_analysis/analysis_span.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/identity/cloud_failure_kind.dart';
import 'package:reader/identity/cloud_service_exception.dart';
import 'package:reader/text/text_position.dart';

/// Deterministic server boundary; source normalization and local storage stay real.
/// GET observes only. Extraction/finalization advance only through explicit POSTs.
class FakeBookAnalysisApi implements BookAnalysisApi {
  FakeBookAnalysisApi({
    this.beforeRequest,
    this.surfaces = const {
      'Mara': EntityKind.individual,
      'e\u0301': EntityKind.individual,
      '👩🏽‍🚀': EntityKind.individual,
    },
  });

  @override
  bool configured = true;
  bool enabled = true;
  bool signedOut = false;
  bool failProvider = false;
  bool lostChunkResponse = false;
  String accountKey = sha256
      .convert(utf8.encode('analysis-owner-a'))
      .toString();
  Future<void> Function(String operation)? beforeRequest;
  final Map<String, EntityKind> surfaces;
  int configCalls = 0;
  final registrations = <CatalogBook>[];
  final manifests = <AnalysisSourceManifest>[];
  final uploads = <AnalysisChunkInput>[];
  final uploadGenerations = <String>[];
  final finalizations = <String>[];
  final pages = <String, AnalysisResultPage>{};
  final _generations = <String, _Generation>{};

  String bookIdFor(CatalogBook book) => sha256
      .convert(utf8.encode('$accountKey:${book.hash}'))
      .toString()
      .substring(0, 40);

  Future<void> _before(String operation) async {
    await beforeRequest?.call(operation);
    if (signedOut) {
      throw const CloudServiceException(
        CloudFailureKind.signedOut,
        'No session.',
      );
    }
  }

  @override
  Future<AnalysisConfiguration> getConfiguration() async {
    configCalls++;
    await _before('config');
    return AnalysisConfiguration(enabled: enabled, accountKey: accountKey);
  }

  @override
  Future<AnalysisRegistration> registerBook(
    CatalogBook book, {
    required int sectionCount,
  }) async {
    await _before('register');
    registrations.add(book);
    return AnalysisRegistration(
      bookId: bookIdFor(book),
      accountKey: accountKey,
    );
  }

  @override
  Future<AnalysisReceipt> admitGeneration(
    AnalysisSourceManifest manifest,
    String cloudBookId,
  ) async {
    await _before('admit');
    final id = sha256
        .convert(
          utf8.encode('$accountKey:$cloudBookId:${manifest.documentDigest}'),
        )
        .toString();
    if (!_generations.containsKey(id)) {
      manifests.add(manifest);
      _generations[id] = _Generation(manifest, cloudBookId, accountKey);
    }
    return AnalysisReceipt(generationId: id, status: _generations[id]!.status);
  }

  @override
  Future<void> putManifestPage(
    String generationId,
    int pageOrdinal,
    AnalysisDescriptorPage page,
  ) async {
    await _before('manifest');
    final generation = _generations[generationId]!;
    final previous = generation.descriptors[pageOrdinal];
    if (previous != null &&
        jsonEncode(previous.toJson()) != jsonEncode(page.toJson())) {
      throw StateError('Conflicting descriptor retry.');
    }
    generation.descriptors[pageOrdinal] = page;
    if (generation.status == AnalysisGenerationStatus.manifest &&
        generation.descriptors.length == generation.manifest.pageCount) {
      generation.status = AnalysisGenerationStatus.extracting;
    }
  }

  @override
  Future<AnalysisReceipt> submitChunk(
    String generationId,
    AnalysisChunkInput chunk,
  ) async {
    await _before('chunk');
    final generation = _generations[generationId]!;
    if (generation.descriptors.length != generation.manifest.pageCount) {
      throw StateError('Incomplete manifest.');
    }
    final prior = generation.chunks[chunk.ordinal];
    if (prior != null &&
        jsonEncode(prior.toJson()) != jsonEncode(chunk.toJson())) {
      throw StateError('Conflicting chunk retry.');
    }
    if (prior == null) {
      if (chunk.ordinal != generation.chunks.length) {
        throw StateError('Earlier analysis window is incomplete.');
      }
      generation.chunks[chunk.ordinal] = chunk;
      uploads.add(chunk);
      uploadGenerations.add(generationId);
      generation.status = failProvider
          ? AnalysisGenerationStatus.failed
          : generation.chunks.length == generation.manifest.chunkCount
          ? AnalysisGenerationStatus.finalizing
          : AnalysisGenerationStatus.extracting;
    }
    if (lostChunkResponse) {
      lostChunkResponse = false;
      throw const CloudServiceException(
        CloudFailureKind.offline,
        'Lost response.',
      );
    }
    return AnalysisReceipt(
      generationId: generationId,
      jobId: sha256
          .convert(utf8.encode('$generationId-extract-${chunk.ordinal}'))
          .toString(),
      status: generation.status,
    );
  }

  @override
  Future<AnalysisProgress> getProgress(String generationId) async {
    await _before('progress');
    final generation = _generations[generationId]!;
    final manifest = generation.manifest;
    final complete = generation.status == AnalysisGenerationStatus.complete;
    final failed = generation.status == AnalysisGenerationStatus.failed;
    final manifestPending =
        generation.status == AnalysisGenerationStatus.manifest;
    final extracting = generation.status == AnalysisGenerationStatus.extracting;
    final stage = complete
        ? AnalysisStage.publish
        : manifestPending
        ? AnalysisStage.manifest
        : extracting
        ? AnalysisStage.extract
        : AnalysisStage.reconcile;
    return AnalysisProgress(
      generationId: generationId,
      bookId: generation.bookId,
      accountKey: generation.owner,
      documentDigest: manifest.documentDigest,
      status: generation.status,
      stage: stage,
      processedChunks: failed ? 0 : generation.chunks.length,
      requiredChunks: manifest.chunkCount,
      processedUnits: failed
          ? 0
          : generation.chunks.values.fold<int>(
              0,
              (sum, chunk) =>
                  sum +
                  chunk.primary.fold<int>(0, (n, span) => n + span.text.length),
            ),
      requiredUnits: manifest.chunks.fold<int>(
        0,
        (sum, chunk) =>
            sum +
            chunk.primary.fold<int>(
              0,
              (n, span) => n + span.endOffset - span.startOffset,
            ),
      ),
      nextCursor: complete || failed
          ? null
          : AnalysisOperationCursor(
              stage: stage,
              ordinal: manifestPending
                  ? generation.descriptors.length
                  : extracting
                  ? generation.chunks.length
                  : 0,
            ),
      error: failed ? const AnalysisFailure(category: 'provider_failed') : null,
      finalizedRevision: complete
          ? sha256.convert(utf8.encode('$generationId-revision-1')).toString()
          : null,
      resultPages: complete ? generation.resultPages : const [],
    );
  }

  @override
  Future<AnalysisReceipt> finalize(String generationId) async {
    await _before('finalize');
    final generation = _generations[generationId]!;
    if (generation.status == AnalysisGenerationStatus.failed ||
        generation.chunks.length != generation.manifest.chunkCount) {
      throw StateError('Cannot publish incomplete extraction.');
    }
    if (generation.status != AnalysisGenerationStatus.complete) {
      finalizations.add(generationId);
      _publish(generationId, generation);
      generation.status = AnalysisGenerationStatus.complete;
    }
    return AnalysisReceipt(
      generationId: generationId,
      jobId: sha256.convert(utf8.encode('$generationId-finalize-0')).toString(),
      status: generation.status,
      cursor: const AnalysisOperationCursor(
        stage: AnalysisStage.publish,
        ordinal: 0,
      ),
    );
  }

  void _publish(String generationId, _Generation generation) {
    final entities = <String, AnalysisEntity>{};
    final mentions = <AnalysisMention>[];
    for (final chunk in generation.chunks.values) {
      // Deliberately ignore overlap: evidence belongs to primary coverage once.
      for (final source in chunk.primary) {
        for (final surface in surfaces.entries) {
          for (var from = 0; ;) {
            final offset = source.text.indexOf(surface.key, from);
            if (offset < 0) break;
            final start = TextPosition(
              sectionId: source.sectionId,
              blockId: source.blockId,
              offset: source.startOffset + offset,
            );
            final end = TextPosition(
              sectionId: source.sectionId,
              blockId: source.blockId,
              offset: start.offset + surface.key.length,
            );
            final span = AnalysisSpan(start: start, end: end);
            final entityId =
                '$generationId-entity-${surfaces.keys.toList().indexOf(surface.key)}';
            entities.putIfAbsent(
              entityId,
              () => AnalysisEntity(
                id: entityId,
                kind: surface.value,
                firstIntroduction: start,
                names: [
                  AnalysisName(
                    text: surface.key,
                    role: AnalysisMentionRole.name,
                    evidence: [span],
                    revealAt: end,
                  ),
                ],
              ),
            );
            mentions.add(
              AnalysisMention(
                id: '$generationId-mention-${mentions.length}',
                entityId: entityId,
                span: span,
                surface: surface.key,
                role: AnalysisMentionRole.name,
              ),
            );
            from = offset + surface.key.length;
          }
        }
      }
    }
    final results = [
      AnalysisResultPage(
        generationId: generationId,
        pageId: 'entities-0',
        kind: AnalysisResultPageKind.entities,
        ordinal: 0,
        entities: entities.values.toList(),
      ),
      AnalysisResultPage(
        generationId: generationId,
        pageId: 'mentions-0',
        kind: AnalysisResultPageKind.mentions,
        ordinal: 0,
        mentions: mentions,
      ),
    ];
    for (final page in results) {
      final bytes = utf8.encode(page.serializedJson);
      pages['$generationId/${page.pageId}'] = page;
      generation.resultPages.add(
        AnalysisResultPageDescriptor(
          pageId: page.pageId,
          kind: page.kind,
          ordinal: page.ordinal,
          checksum: sha256.convert(bytes).toString(),
          byteLength: bytes.length,
        ),
      );
    }
  }

  @override
  Future<AnalysisResultPage> getPage(String generationId, String pageId) async {
    await _before('page');
    if (_generations[generationId]!.status !=
        AnalysisGenerationStatus.complete) {
      throw StateError('Result is not finalized.');
    }
    return pages['$generationId/$pageId']!;
  }
}

class _Generation {
  _Generation(this.manifest, this.bookId, this.owner);
  final AnalysisSourceManifest manifest;
  final String bookId;
  final String owner;
  AnalysisGenerationStatus status = AnalysisGenerationStatus.manifest;
  final descriptors = <int, AnalysisDescriptorPage>{};
  final chunks = <int, AnalysisChunkInput>{};
  final resultPages = <AnalysisResultPageDescriptor>[];
}
