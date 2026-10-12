import '../catalog/catalog_book.dart';
import 'analysis_protocol.dart';
import 'analysis_result.dart';
import 'analysis_versions.dart';

/// Default-enabled preprocessing state, independent of image eligibility.
enum BookAnalysisStatus {
  waitingConsent,
  waitingAccount,
  waitingService,
  waitingConnection,
  queued,
  extracting,
  finalizing,
  complete,
  failed,
}

/// Pointer switched only after every immutable page is locally durable.
class AnalysisFinalizedPointer {
  const AnalysisFinalizedPointer({
    required this.generationId,
    required this.revision,
    required this.accountKey,
    required this.documentVersion,
    required this.documentDigest,
    required this.pages,
  });

  final String generationId;
  final String revision;
  final String accountKey;
  final int documentVersion;
  final String documentDigest;
  final List<AnalysisResultPageDescriptor> pages;

  Map<String, dynamic> toJson() => {
    'generationId': generationId,
    'revision': revision,
    'accountKey': accountKey,
    'documentVersion': documentVersion,
    'documentDigest': documentDigest,
    'pages': pages.map((page) => page.toJson()).toList(),
  };

  factory AnalysisFinalizedPointer.fromJson(Map<String, dynamic> json) =>
      AnalysisFinalizedPointer(
        generationId: json['generationId'] as String,
        revision: json['revision'] as String,
        accountKey: json['accountKey'] as String,
        documentVersion: json['documentVersion'] as int,
        documentDigest: json['documentDigest'] as String,
        pages: List.unmodifiable(
          (json['pages'] as List).map(
            (item) => AnalysisResultPageDescriptor.fromJson(
              (item as Map).cast<String, dynamic>(),
            ),
          ),
        ),
      );
}

/// Bounded prose-free metadata; source descriptors are regenerated on restart.
class BookAnalysisState {
  const BookAnalysisState({
    this.schemaVersion = analysisSchemaVersion,
    this.analysisVersion = bookAnalysisVersion,
    this.promptVersion = analysisPromptVersion,
    this.model = analysisModel,
    required this.bookHash,
    required this.bookPath,
    required this.addedAt,
    this.status = BookAnalysisStatus.queued,
    this.documentVersion,
    this.documentDigest,
    this.accountKey,
    this.cloudBookId,
    this.receipt,
    this.progress,
    this.manifestPagesUploaded = 0,
    this.finalized,
    this.failureCategory,
    this.unavailable = false,
  });

  factory BookAnalysisState.forBook(CatalogBook book) => BookAnalysisState(
    bookHash: book.hash,
    bookPath: book.path,
    addedAt: book.addedAt,
  );

  final int schemaVersion;
  final int analysisVersion;
  final int promptVersion;
  final String model;
  final String bookHash;
  final String bookPath;
  final DateTime addedAt;
  final BookAnalysisStatus status;
  final int? documentVersion;
  final String? documentDigest;
  final String? accountKey;
  final String? cloudBookId;
  final AnalysisReceipt? receipt;
  final AnalysisProgress? progress;
  final int manifestPagesUploaded;
  final AnalysisFinalizedPointer? finalized;
  final String? failureCategory;

  /// An unsupported future sidecar is never overwritten.
  final bool unavailable;

  int get processedChunks => progress?.processedChunks ?? 0;
  int get requiredChunks => progress?.requiredChunks ?? 0;
  int get processedUnits => progress?.processedUnits ?? 0;
  int get requiredUnits => progress?.requiredUnits ?? 0;
  String? get generationId => receipt?.generationId;

  /// Compares the instant: a local-time import and its UTC-decoded sidecar are
  /// the same book, which `DateTime ==` would reject.
  bool matchesBook(CatalogBook book) =>
      book.hash == bookHash &&
      book.path == bookPath &&
      book.addedAt.isAtSameMomentAs(addedAt);

  BookAnalysisState copyWith({
    BookAnalysisStatus? status,
    int? documentVersion,
    String? documentDigest,
    String? accountKey,
    String? cloudBookId,
    AnalysisReceipt? receipt,
    AnalysisProgress? progress,
    int? manifestPagesUploaded,
    AnalysisFinalizedPointer? finalized,
    String? failureCategory,
    bool clearFailure = false,
    bool clearGeneration = false,
    bool clearOwner = false,
  }) => BookAnalysisState(
    schemaVersion: schemaVersion,
    analysisVersion: analysisVersion,
    promptVersion: promptVersion,
    model: model,
    bookHash: bookHash,
    bookPath: bookPath,
    addedAt: addedAt,
    status: status ?? this.status,
    documentVersion: documentVersion ?? this.documentVersion,
    documentDigest: documentDigest ?? this.documentDigest,
    accountKey: clearOwner ? null : accountKey ?? this.accountKey,
    cloudBookId: clearOwner ? null : cloudBookId ?? this.cloudBookId,
    receipt: clearOwner || clearGeneration ? null : receipt ?? this.receipt,
    progress: clearOwner || clearGeneration ? null : progress ?? this.progress,
    manifestPagesUploaded: clearOwner || clearGeneration
        ? 0
        : manifestPagesUploaded ?? this.manifestPagesUploaded,
    finalized: clearOwner ? null : finalized ?? this.finalized,
    failureCategory: clearFailure
        ? null
        : failureCategory ?? this.failureCategory,
    unavailable: unavailable,
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'analysisVersion': analysisVersion,
    'promptVersion': promptVersion,
    'model': model,
    'bookHash': bookHash,
    'bookPath': bookPath,
    'addedAt': addedAt.toUtc().toIso8601String(),
    'status': status.name,
    if (documentVersion != null) 'documentVersion': documentVersion,
    if (documentDigest != null) 'documentDigest': documentDigest,
    if (accountKey != null) 'accountKey': accountKey,
    if (cloudBookId != null) 'cloudBookId': cloudBookId,
    if (receipt != null) 'receipt': receipt!.toJson(),
    if (progress != null) 'progress': progress!.toJson(),
    'manifestPagesUploaded': manifestPagesUploaded,
    if (finalized != null) 'finalized': finalized!.toJson(),
    if (failureCategory != null) 'failureCategory': failureCategory,
  };

  factory BookAnalysisState.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != analysisSchemaVersion ||
        json['analysisVersion'] != bookAnalysisVersion ||
        json['promptVersion'] != analysisPromptVersion ||
        json['model'] != analysisModel) {
      throw const FormatException('Unsupported analysis state.');
    }
    return BookAnalysisState(
      bookHash: json['bookHash'] as String,
      bookPath: json['bookPath'] as String,
      addedAt: DateTime.parse(json['addedAt'] as String),
      status: BookAnalysisStatus.values.byName(json['status'] as String),
      documentVersion: json['documentVersion'] as int?,
      documentDigest: json['documentDigest'] as String?,
      accountKey: json['accountKey'] as String?,
      cloudBookId: json['cloudBookId'] as String?,
      receipt: json['receipt'] == null
          ? null
          : AnalysisReceipt.fromJson(
              (json['receipt'] as Map).cast<String, dynamic>(),
            ),
      progress: json['progress'] == null
          ? null
          : AnalysisProgress.fromJson(
              (json['progress'] as Map).cast<String, dynamic>(),
            ),
      manifestPagesUploaded: json['manifestPagesUploaded'] as int? ?? 0,
      finalized: json['finalized'] == null
          ? null
          : AnalysisFinalizedPointer.fromJson(
              (json['finalized'] as Map).cast<String, dynamic>(),
            ),
      failureCategory: json['failureCategory'] as String?,
    );
  }
}
