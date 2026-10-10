/// Outcome categories reported independently for each selected file.
enum ImportStatus {
  /// The source book was validated and committed.
  imported,

  /// An identical SHA-256 hash already exists in the catalog.
  duplicate,

  /// Validation, parsing, or storage failed.
  failed,
}

/// User-facing result of one book import attempt.
class ImportResult {
  /// Creates an outcome for one selected filename.
  const ImportResult(this.fileName, this.status, {this.message});

  /// Original selected filename.
  final String fileName;

  /// Result category.
  final ImportStatus status;

  /// Optional validation or platform error suitable for display.
  final String? message;
}
