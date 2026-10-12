import 'dart:async';

import 'package:flutter/foundation.dart';

import '../importing/book_importer.dart';
import '../importing/book_picker.dart';
import '../importing/import_result.dart';
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
    required this.changed,
    this.acceptedBook,
  });

  /// Persists complete catalog snapshots and owns source-directory deletion.
  final CatalogStore store;

  /// Stages and commits one imported source at a time.
  final BookImporter importer;

  /// Supplies user-selected import candidates.
  final BookPicker picker;

  /// Runs only after an accepted import's catalog snapshot is durable.
  /// The composition root queues noninteractive work and must not throw.
  final void Function(CatalogBook)? acceptedBook;

  /// Authoritative live catalog records.
  List<CatalogBook> books = [];

  /// Whether a serial import is active.
  bool importing = false;

  /// Completed candidates in the current import.
  int importDone = 0;

  /// Total candidates in the current import.
  int importTotal = 0;

  /// Publishes catalog transactions through the app's sole shared notifier.
  final VoidCallback changed;
  Timer? _positionSave;
  Future<void>? _positionWrite;
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
    changed();
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
          acceptedBook?.call(imported.book!);
        }
        importDone++;
        changed();
      }
      return results;
    } finally {
      importing = false;
      changed();
    }
  }

  /// Live catalog row with the same hash, or null when it is not cataloged.
  CatalogBook? find(CatalogBook book) =>
      books.where((item) => item.hash == book.hash).firstOrNull;

  /// Whether [book]'s exact import is still cataloged; a deleted or reimported
  /// book is not live.
  bool isLive(CatalogBook book) => books.any(
    (item) =>
        item.hash == book.hash &&
        item.path == book.path &&
        item.addedAt == book.addedAt,
  );

  /// Updates live recency synchronously and returns the corresponding save.
  Future<void> markOpened(CatalogBook book) {
    final current = find(book);
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
    if (_disposed) return null;
    final current = find(book);
    if (current == null) return null;
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
      // A later full save in [flush] supersedes a failed debounced write;
      // clearing on settle keeps flush from awaiting a finished write.
      late final Future<void> write;
      write = store
          .save(books)
          .then<void>((_) {}, onError: (Object _, StackTrace _) {})
          .whenComplete(() {
            if (identical(_positionWrite, write)) _positionWrite = null;
          });
      _positionWrite = write;
    });
    return null;
  }

  /// Removes matching hashes without notifying or performing I/O.
  void removeFromMemory(CatalogBook book) {
    books = books.where((item) => item.hash != book.hash).toList();
  }

  /// Saves the complete current catalog without cancelling the debounce timer.
  Future<void> persist() => store.save(books);

  /// Cancels debounce, waits for any debounced write, and saves the catalog,
  /// including after disposal.
  Future<void> flush() async {
    _positionSave?.cancel();
    final write = _positionWrite;
    if (write != null) await write;
    await store.save(books);
  }

  void _replace(CatalogBook updated) {
    books = books
        .map((book) => book.hash == updated.hash ? updated : book)
        .toList();
    changed();
  }

  /// Fences delayed position work without closing services or writing.
  void dispose() {
    _disposed = true;
    _positionSave?.cancel();
  }
}
