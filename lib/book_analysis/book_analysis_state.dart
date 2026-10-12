import '../catalog/catalog_book.dart';
import 'analysis_protocol.dart';
import 'analysis_result.dart';
import 'analysis_model.dart';

/// Default-enabled preprocessing state, independent of image eligibility.
enum BookAnalysisStatus {
  /// Source upload is blocked until cloud-processing consent is granted.
  waitingConsent,

  /// Work requires an existing signed-in account; never prompts for sign-in.
  waitingAccount,

  /// The authenticated analysis rollout or configured model is unavailable.
  waitingService,

  /// Remote work is paused until connectivity returns.
  waitingConnection,

  /// Eligible preprocessing awaits its next background operation.
  queued,

  /// Ordered primary source windows are being analyzed.
  extracting,

  /// Derived records are being reconciled and indexed before publication.
  finalizing,

  /// All finalized result pages are locally committed.
  complete,

  /// Processing stopped with a sanitized failure category.
  failed,
}

/// Pointer switched only after every immutable page is locally durable.
class AnalysisFinalizedPointer {
  /// Binds a committed page set to its generation, owner and normalized source.
  const AnalysisFinalizedPointer({
    required this.generationId,
    required this.revision,
    required this.accountKey,
    required this.documentDigest,
    required this.pages,
  });

  /// Immutable server generation that produced the committed pages.
  final String generationId;

  /// Content identity of the atomically published result set.
  final String revision;

  /// Opaque account fence preventing cross-account result reuse.
  final String accountKey;

  /// Exact normalized source digest shared by every committed page.
  final String documentDigest;

  /// Complete immutable page references, durable before this pointer is saved.
  final List<AnalysisResultPageDescriptor> pages;

  /// Persists the committed result identity without source prose.
  Map<String, dynamic> toJson() => {
    'generationId': generationId,
    'revision': revision,
    'accountKey': accountKey,
    'documentDigest': documentDigest,
    'pages': pages.map((page) => page.toJson()).toList(),
  };

  /// Restores references; the store validates ownership and page durability.
  factory AnalysisFinalizedPointer.fromJson(Map<String, dynamic> json) =>
      AnalysisFinalizedPointer(
        generationId: json['generationId'] as String,
        revision: json['revision'] as String,
        accountKey: json['accountKey'] as String,
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
  /// Captures import identity and resumable work without retaining source prose.
  const BookAnalysisState({
    this.model = analysisModel,
    required this.bookHash,
    required this.bookPath,
    required this.addedAt,
    this.status = BookAnalysisStatus.queued,
    this.documentDigest,
    this.accountKey,
    this.cloudBookId,
    this.receipt,
    this.progress,
    this.manifestPagesUploaded = 0,
    this.finalized,
    this.failureCategory,
  });

  /// Starts preprocessing for this exact import, not merely the same book hash.
  factory BookAnalysisState.forBook(CatalogBook book) => BookAnalysisState(
    bookHash: book.hash,
    bookPath: book.path,
    addedAt: book.addedAt,
  );

  /// Extraction model pinned for the lifetime of this state.
  final String model;

  /// Content-addressed imported book identity.
  final String bookHash;

  /// Local source directory distinguishing imports with the same content.
  final String bookPath;

  /// Import instant fencing results from deleted and reimported books.
  final DateTime addedAt;

  /// Local lifecycle, including prerequisites absent from server progress.
  final BookAnalysisStatus status;

  /// Normalized coverage identity, absent until source mapping completes.
  final String? documentDigest;

  /// Opaque owner fence, absent before authenticated registration.
  final String? accountKey;

  /// Owned remote book identity used for analysis and deletion.
  final String? cloudBookId;

  /// Durable admitted intent used to resume without duplicating remote work.
  final AnalysisReceipt? receipt;

  /// Latest read-only server coverage and finalization snapshot.
  final AnalysisProgress? progress;

  /// Count of sequential descriptor pages acknowledged by the server.
  final int manifestPagesUploaded;

  /// Last fully durable result set, retained while replacement work proceeds.
  final AnalysisFinalizedPointer? finalized;

  /// Sanitized failure category; never provider responses or source text.
  final String? failureCategory;

  /// Validated primary windows, or zero before any progress snapshot.
  int get processedChunks => progress?.processedChunks ?? 0;

  /// Admitted primary windows, or zero before any progress snapshot.
  int get requiredChunks => progress?.requiredChunks ?? 0;

  /// Validated primary UTF-16 units, excluding overlap context.
  int get processedUnits => progress?.processedUnits ?? 0;

  /// Admitted primary UTF-16 units, excluding overlap context.
  int get requiredUnits => progress?.requiredUnits ?? 0;

  /// Active admitted generation; may differ from the retained finalized set.
  String? get generationId => receipt?.generationId;

  /// Compares the instant: a local-time import and its UTC-decoded sidecar are
  /// the same book, which `DateTime ==` would reject.
  bool matchesBook(CatalogBook book) =>
      book.hash == bookHash &&
      book.path == bookPath &&
      book.addedAt.isAtSameMomentAs(addedAt);

  /// Updates resumable work while preserving the exact import and model.
  ///
  /// Clearing a generation retains finalized results; clearing its owner also
  /// removes those results so another account cannot reuse them.
  BookAnalysisState copyWith({
    BookAnalysisStatus? status,
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
    model: model,
    bookHash: bookHash,
    bookPath: bookPath,
    addedAt: addedAt,
    status: status ?? this.status,
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
  );

  /// Persists prose-free lifecycle metadata with a timezone-independent instant.
  Map<String, dynamic> toJson() => {
    'model': model,
    'bookHash': bookHash,
    'bookPath': bookPath,
    'addedAt': addedAt.toUtc().toIso8601String(),
    'status': status.name,
    if (documentDigest != null) 'documentDigest': documentDigest,
    if (accountKey != null) 'accountKey': accountKey,
    if (cloudBookId != null) 'cloudBookId': cloudBookId,
    if (receipt != null) 'receipt': receipt!.toJson(),
    if (progress != null) 'progress': progress!.toJson(),
    'manifestPagesUploaded': manifestPagesUploaded,
    if (finalized != null) 'finalized': finalized!.toJson(),
    if (failureCategory != null) 'failureCategory': failureCategory,
  };

  /// Restores the pinned model's state; the store checks import and owner fences.
  factory BookAnalysisState.fromJson(Map<String, dynamic> json) {
    if (json['model'] != analysisModel) {
      throw const FormatException('Unsupported analysis state.');
    }
    return BookAnalysisState(
      bookHash: json['bookHash'] as String,
      bookPath: json['bookPath'] as String,
      addedAt: DateTime.parse(json['addedAt'] as String),
      status: BookAnalysisStatus.values.byName(json['status'] as String),
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
