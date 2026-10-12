import 'analysis_result.dart';
import 'analysis_versions.dart';

/// Server generation states, distinct from local consent/account waiting states.
enum AnalysisGenerationStatus {
  /// Descriptor coverage is still being uploaded/validated.
  manifest,

  /// Sequential primary windows are being processed.
  extracting,

  /// Whole-book reconciliation and indexing are incomplete.
  finalizing,

  /// All immutable result shards are atomically published.
  complete,

  /// Terminal sanitized failure; no automatic paid re-extraction.
  failed,
}

/// Restartable bounded operation stage, controlled by authenticated dispatch.
enum AnalysisStage {
  /// Ordered descriptor page upload.
  manifest('manifest'),

  /// One primary extraction window.
  extract('extract'),

  /// One supported identity-resolution batch.
  reconcile('reconcile'),

  /// One resolved derived-record shard.
  materialize('materialize'),

  /// One temporal/world retrieval index shard; `index` is the wire name.
  indexing('index'),

  /// Complete immutable manifest publication.
  publish('publish');

  const AnalysisStage(this.wire);

  /// Server protocol name; Dart cannot use `index` on an enum member.
  final String wire;

  /// Rejects stage names this client does not understand.
  static AnalysisStage fromWire(String value) =>
      values.firstWhere((stage) => stage.wire == value);
}

/// Server-owned next operation, never an instruction to dispatch from GET alone.
class AnalysisOperationCursor {
  /// Captures exactly one bounded admission cursor.
  const AnalysisOperationCursor({required this.stage, required this.ordinal});

  /// Current operation stage.
  final AnalysisStage stage;

  /// Zero-based bounded-unit ordinal within this stage.
  final int ordinal;

  /// Durable resume cursor.
  Map<String, dynamic> toJson() => {'stage': stage.wire, 'ordinal': ordinal};

  /// Restores the server-owned cursor without admitting work.
  factory AnalysisOperationCursor.fromJson(Map<String, dynamic> json) =>
      AnalysisOperationCursor(
        stage: AnalysisStage.fromWire(json['stage'] as String),
        ordinal: json['ordinal'] as int,
      );
}

/// Sanitized failure metadata; never provider bodies, credentials or raw prose.
class AnalysisFailure {
  /// Stores only the public category supplied by the server.
  const AnalysisFailure({required this.category});

  /// Sanitized, stable failure category.
  final String category;

  /// Durable failure representation.
  Map<String, dynamic> toJson() => {'category': category};

  /// Restores sanitized server failure metadata.
  factory AnalysisFailure.fromJson(Map<String, dynamic> json) =>
      AnalysisFailure(category: json['category'] as String);
}

/// Read-only authenticated availability, independent of image providers/credits.
class AnalysisConfiguration {
  /// Owner key is opaque, account-specific and never a Firebase UID.
  const AnalysisConfiguration({
    this.schemaVersion = analysisSchemaVersion,
    this.analysisVersion = bookAnalysisVersion,
    this.model = analysisModel,
    required this.enabled,
    required this.accountKey,
  });

  /// Supported public wire contract.
  final int schemaVersion;

  /// Supported extraction/reconciliation contract.
  final int analysisVersion;

  /// Existing feature rollout admission flag.
  final bool enabled;

  /// Immutable configured extraction model.
  final String model;

  /// HMAC owner fence, never logged or identified by email.
  final String accountKey;

  /// Configuration snapshot; contains no provider secrets.
  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'analysisVersion': analysisVersion,
    'enabled': enabled,
    'model': model,
    'accountKey': accountKey,
  };

  /// Rejects future schemas/models rather than silently changing generation identity.
  factory AnalysisConfiguration.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != analysisSchemaVersion ||
        json['analysisVersion'] != bookAnalysisVersion ||
        json['model'] != analysisModel) {
      throw const FormatException('Unsupported analysis configuration.');
    }
    return AnalysisConfiguration(
      enabled: json['enabled'] as bool,
      accountKey: json['accountKey'] as String,
    );
  }
}

/// Preprocessing-only owned book registration; no profile or image-credit state.
class AnalysisRegistration {
  /// Shared cloud book identity uses the existing account-salted fingerprint.
  const AnalysisRegistration({required this.bookId, required this.accountKey});

  /// Shared cloud book ID used by the existing book deletion boundary.
  final String bookId;

  /// Opaque owner fence captured with the registration.
  final String accountKey;

  /// Durable owned registration receipt.
  Map<String, dynamic> toJson() => {'bookId': bookId, 'accountKey': accountKey};

  /// Restores the server-derived registration identity.
  factory AnalysisRegistration.fromJson(Map<String, dynamic> json) =>
      AnalysisRegistration(
        bookId: json['bookId'] as String,
        accountKey: json['accountKey'] as String,
      );
}

/// Idempotent admission/operation receipt persisted before advancing locally.
class AnalysisReceipt {
  /// Missing job/cursor fields remain absent, not synthesized local intents.
  const AnalysisReceipt({
    required this.generationId,
    this.jobId,
    required this.status,
    this.cursor,
  });

  /// Immutable generation identity returned by admission.
  final String generationId;

  /// Immutable bounded operation intent, when admitted.
  final String? jobId;

  /// Server generation status at receipt time.
  final AnalysisGenerationStatus status;

  /// Optional current admitted operation cursor.
  final AnalysisOperationCursor? cursor;

  /// Durable retry/resume receipt without raw upload text.
  Map<String, dynamic> toJson() => {
    'generationId': generationId,
    if (jobId != null) 'jobId': jobId,
    'status': status.name,
    if (cursor != null) 'cursor': cursor!.toJson(),
  };

  /// Adopts existing server intent after lost responses, never adds duplicate work.
  factory AnalysisReceipt.fromJson(Map<String, dynamic> json) =>
      AnalysisReceipt(
        generationId: json['generationId'] as String,
        jobId: json['jobId'] as String?,
        status: AnalysisGenerationStatus.values.byName(
          json['status'] as String,
        ),
        cursor: json['cursor'] == null
            ? null
            : AnalysisOperationCursor.fromJson(
                (json['cursor'] as Map).cast<String, dynamic>(),
              ),
      );
}

/// Read-only coverage, operation cursor and finalized revision snapshot.
class AnalysisProgress {
  /// Completed old revisions may remain visible while replacement work fails.
  const AnalysisProgress({
    required this.generationId,
    required this.bookId,
    required this.accountKey,
    required this.documentVersion,
    required this.documentDigest,
    required this.status,
    required this.stage,
    required this.processedChunks,
    required this.requiredChunks,
    required this.processedUnits,
    required this.requiredUnits,
    required this.nextCursor,
    required this.error,
    required this.finalizedRevision,
    required this.resultPages,
  });

  /// Owned generation being observed.
  final String generationId;

  /// Shared owned cloud book identity.
  final String bookId;

  /// Opaque account owner fence.
  final String accountKey;

  /// Exact normalized document version.
  final int documentVersion;

  /// Exact normalized primary-coverage digest.
  final String documentDigest;

  /// Durable server generation state.
  final AnalysisGenerationStatus status;

  /// Current bounded operation stage.
  final AnalysisStage stage;

  /// Successfully validated primary window count.
  final int processedChunks;

  /// Complete admitted primary window count, including empty windows.
  final int requiredChunks;

  /// Successfully validated primary UTF-16 units, excluding context.
  final int processedUnits;

  /// Complete admitted primary UTF-16 units, excluding context.
  final int requiredUnits;

  /// Next explicit admission cursor, null when no work is actionable.
  final AnalysisOperationCursor? nextCursor;

  /// Terminal sanitized failure, if any.
  final AnalysisFailure? error;

  /// Atomically published immutable revision identity, if available.
  final String? finalizedRevision;

  /// Only finalized immutable page references, never staging pages.
  final List<AnalysisResultPageDescriptor> resultPages;

  /// Durable progress snapshot contains no source text.
  Map<String, dynamic> toJson() => {
    'generationId': generationId,
    'bookId': bookId,
    'accountKey': accountKey,
    'documentVersion': documentVersion,
    'documentDigest': documentDigest,
    'status': status.name,
    'stage': stage.wire,
    'processedChunks': processedChunks,
    'requiredChunks': requiredChunks,
    'processedUnits': processedUnits,
    'requiredUnits': requiredUnits,
    'nextCursor': nextCursor?.toJson(),
    'error': error?.toJson(),
    'finalizedRevision': finalizedRevision,
    'resultPages': resultPages.map((page) => page.toJson()).toList(),
  };

  /// Restores progress without causing registration, extraction or credit mutation.
  factory AnalysisProgress.fromJson(Map<String, dynamic> json) =>
      AnalysisProgress(
        generationId: json['generationId'] as String,
        bookId: json['bookId'] as String,
        accountKey: json['accountKey'] as String,
        documentVersion: json['documentVersion'] as int,
        documentDigest: json['documentDigest'] as String,
        status: AnalysisGenerationStatus.values.byName(
          json['status'] as String,
        ),
        stage: AnalysisStage.fromWire(json['stage'] as String),
        processedChunks: json['processedChunks'] as int,
        requiredChunks: json['requiredChunks'] as int,
        processedUnits: json['processedUnits'] as int,
        requiredUnits: json['requiredUnits'] as int,
        nextCursor: json['nextCursor'] == null
            ? null
            : AnalysisOperationCursor.fromJson(
                (json['nextCursor'] as Map).cast<String, dynamic>(),
              ),
        error: json['error'] == null
            ? null
            : AnalysisFailure.fromJson(
                (json['error'] as Map).cast<String, dynamic>(),
              ),
        finalizedRevision: json['finalizedRevision'] as String?,
        resultPages: List.unmodifiable(
          (json['resultPages'] as List).map(
            (item) => AnalysisResultPageDescriptor.fromJson(
              (item as Map).cast<String, dynamic>(),
            ),
          ),
        ),
      );
}
