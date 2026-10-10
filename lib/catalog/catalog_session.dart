import 'dart:async';

import 'package:flutter/foundation.dart';

import '../importing/book_importer.dart';
import '../importing/book_picker.dart';
import '../importing/import_result.dart';
import '../text/book_word_counter.dart';
import '../text/text_position.dart';
import 'catalog_book.dart';
import 'catalog_store.dart';

/// Owns the live catalog, serial imports, and debounced reading-position writes.
///
/// Changes publish through the application's shared notifier. Injected services
/// remain caller-owned; disposal only fences work and cancels the debounce timer.
class CatalogSession {
  /// Installs catalog services and the shared change callback once.
  CatalogSession({
    required this.store,
    required this.importer,
    required this.picker,
    required this.wordCounter,
    required this._changed,
  });

  /// Persists complete catalog snapshots and owns source-directory deletion.
  final CatalogStore store;

  /// Stages and commits one imported source at a time.
  final BookImporter importer;

  /// Supplies user-selected import candidates.
  final BookPicker picker;

  /// Counts normalized text independently of cloud indexing.
  final BookWordCounter wordCounter;

  /// Authoritative live catalog records.
  List<CatalogBook> books = [];

  /// Whether a serial import is active.
  bool importing = false;

  /// Completed candidates in the current import.
  int importDone = 0;

  /// Total candidates in the current import.
  int importTotal = 0;

  final VoidCallback _changed;
  Timer? _positionSave;
  bool _disposed = false;

  /// Restores catalog records without publishing a startup notification.
  Future<void> load() async {
    books = await store.load();
  }

  /// Most recently opened book, used by the Continue reading card.
  CatalogBook? get currentBook {
    final recent = books.where((book) => book.lastOpenedAt != null).toList()
      ..sort((a, b) => b.lastOpenedAt!.compareTo(a.lastOpenedAt!));
    return recent.firstOrNull;
  }

  /// Picks files and imports serially to bound staging memory and duplicate commits.
  Future<List<ImportResult>> pickAndImport() async {
    final candidates = await picker.pick();
    if (candidates.isEmpty) return [];
    importing = true;
    importDone = 0;
    importTotal = candidates.length;
    _changed();
    final results = <ImportResult>[];
    try {
      final hashes = books.map((book) => book.hash).toSet();
      for (final candidate in candidates) {
        final imported = await importer.import(candidate, hashes);
        results.add(imported.result);
        if (imported.book != null) {
          books = [...books, imported.book!];
          hashes.add(imported.book!.hash);
          await store.save(books);
        }
        importDone++;
        _changed();
      }
      return results;
    } finally {
      importing = false;
      _changed();
    }
  }

  /// Updates live recency synchronously and returns the corresponding save.
  Future<void> markOpened(CatalogBook book) {
    final current = books.where((item) => item.hash == book.hash).firstOrNull;
    if (current == null) return Future.value();
    _replace(current.copyWith(lastOpenedAt: DateTime.now()));
    return store.save(books);
  }

  /// Commits the complete anchor synchronously, then saves now or after 500 ms.
  ///
  /// Immediate narration commits return the actual store future. Viewport commits
  /// schedule the debounce and return null so illustration advancement need not
  /// cross an additional asynchronous boundary.
  Future<void>? recordPosition(
    CatalogBook book,
    TextPosition position,
    double progress, {
    required bool immediate,
  }) {
    if (_disposed || !books.any((item) => item.hash == book.hash)) return null;
    final current = books.firstWhere(
      (item) => item.hash == book.hash,
      orElse: () => book,
    );
    _replace(
      current.copyWith(
        lastPosition: position,
        progress: progress.clamp(0, 1),
        lastOpenedAt: DateTime.now(),
      ),
    );
    _positionSave?.cancel();
    if (immediate) return store.save(books);
    _positionSave = Timer(const Duration(milliseconds: 500), () {
      store.save(books);
    });
    return null;
  }

  /// Backfills missing counts, merging only into the matching latest live row.
  ///
  /// Snapshot identities survive asynchronous counting; hash, path, and addedAt
  /// checks prevent resurrecting deleted/reimported books or stale positions.
  Future<void> backfillWordCounts() async {
    for (final candidate in List<CatalogBook>.of(books)) {
      if (_disposed) return;
      if (candidate.wordCount != null) continue;
      try {
        final count = await wordCounter.count(candidate.path);
        if (_disposed) return;
        final current = books
            .where(
              (book) =>
                  book.addedAt == candidate.addedAt &&
                  book.hash == candidate.hash &&
                  book.path == candidate.path,
            )
            .firstOrNull;
        if (current == null || current.wordCount != null) continue;
        _replace(current.copyWith(wordCount: count));
        await store.save(books);
      } on Object {
        // An unreadable section must not stop other books or offline reading.
      }
    }
  }

  /// Removes matching hashes without notifying or performing I/O.
  void removeFromMemory(CatalogBook book) {
    books = books.where((item) => item.hash != book.hash).toList();
  }

  /// Saves the complete current catalog without cancelling the debounce timer.
  Future<void> persist() => store.save(books);

  /// Cancels debounce and saves the catalog, including after disposal.
  Future<void> flush() async {
    _positionSave?.cancel();
    await store.save(books);
  }

  void _replace(CatalogBook updated) {
    books = books
        .map((book) => book.hash == updated.hash ? updated : book)
        .toList();
    _changed();
  }

  /// Fences background count/position work without closing services or writing.
  void dispose() {
    _disposed = true;
    _positionSave?.cancel();
  }
}
