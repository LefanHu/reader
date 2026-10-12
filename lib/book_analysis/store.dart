import '../catalog/catalog_book.dart';
import 'analysis_result.dart';
import 'book_analysis_state.dart';

/// Durable prose-free preprocessing receipts and immutable derived result pages.
abstract interface class AnalysisStore {
  /// Restores only the exact import, with unsupported state reported unavailable.
  Future<BookAnalysisState?> loadState(CatalogBook book);

  /// Persists a state snapshot before advancing its admitted operation.
  Future<void> saveState(CatalogBook book, BookAnalysisState state);

  /// Stores a bounded finalized page under its durable owner/generation receipt.
  Future<void> savePage(
    CatalogBook book,
    String generationId,
    String pageId,
    AnalysisResultPage page,
  );

  /// Validates exact immutable bytes against the durable result descriptor.
  Future<AnalysisResultPage?> loadPage(
    CatalogBook book,
    String generationId,
    String pageId,
  );

  /// Clears only validated app-owned analysis data, preserving book/reading data.
  Future<void> clearAccountData(List<CatalogBook> books);

  /// Waits only for pending local writes, never cloud completion.
  Future<void> flush();
}

/// Optional transactional ownership fencing for stores with asynchronous writes.
///
/// The coordinator registers synchronous predicates capturing its live exact
/// import/account action. They are checked inside serialized transactions and
/// again at atomic publication, not only before entering the store method.
abstract interface class AnalysisWriteFence {
  /// Replaces the live state/page predicates, or removes them when null.
  void setWriteEligibility({
    bool Function(CatalogBook book, BookAnalysisState state)? state,
    bool Function(CatalogBook book, String generationId)? page,
  });
}
