import 'package:reader/book_analysis/analysis_result.dart';
import 'package:reader/book_analysis/book_analysis_state.dart';
import 'package:reader/book_analysis/store.dart';
import 'package:reader/catalog/catalog_book.dart';

/// In-memory atomic write boundary with barriers before transaction eligibility.
class MemoryAnalysisStore implements AnalysisStore, AnalysisWriteFence {
  final states = <String, BookAnalysisState>{};
  final pages = <String, AnalysisResultPage>{};
  Future<void> Function(BookAnalysisState)? beforeStateWrite;
  Future<void> Function(AnalysisResultPage)? beforePageWrite;
  bool Function(CatalogBook, BookAnalysisState)? _stateEligible;
  bool Function(CatalogBook, String)? _pageEligible;
  int committedStates = 0;
  int committedPages = 0;

  @override
  void setWriteEligibility({
    bool Function(CatalogBook, BookAnalysisState)? state,
    bool Function(CatalogBook, String generationId)? page,
  }) {
    _stateEligible = state;
    _pageEligible = page;
  }

  @override
  Future<BookAnalysisState?> loadState(CatalogBook book) async =>
      states[book.hash];

  @override
  Future<void> saveState(CatalogBook book, BookAnalysisState state) async {
    await beforeStateWrite?.call(state);
    if (!(_stateEligible?.call(book, state) ?? true)) return;
    states[book.hash] = BookAnalysisState.fromJson(state.toJson());
    committedStates++;
  }

  @override
  Future<void> savePage(
    CatalogBook book,
    String generationId,
    String pageId,
    AnalysisResultPage page,
  ) async {
    await beforePageWrite?.call(page);
    if (!(_pageEligible?.call(book, generationId) ?? true)) return;
    pages['${book.hash}/$generationId/$pageId'] = AnalysisResultPage.fromJson(
      page.toJson(),
    );
    committedPages++;
  }

  @override
  Future<AnalysisResultPage?> loadPage(
    CatalogBook book,
    String generationId,
    String pageId,
  ) async => pages['${book.hash}/$generationId/$pageId'];

  @override
  Future<void> clearAccountData(List<CatalogBook> books) async {
    for (final book in books) {
      states.remove(book.hash);
      pages.removeWhere((key, _) => key.startsWith('${book.hash}/'));
    }
  }

  @override
  Future<void> flush() async {}
}
