import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flureadium/flureadium.dart';

import 'epub_service.dart';
import 'models.dart';
import 'storage.dart';

/// Owns session state and coordinates the UI, storage, importer, and Readium.
///
/// The controller intentionally remains the app's only state-management
/// object. Platform and persistence dependencies are injected so its behavior
/// can be tested without native plugins.
class ReaderController extends ChangeNotifier {
  /// Creates a controller from explicit platform and persistence dependencies.
  ReaderController({
    required this.catalogStore,
    required this.settingsStore,
    required this.importer,
    required this.picker,
    required this.engine,
  });

  /// Catalog persistence used for every book-state mutation.
  final CatalogStore catalogStore;

  /// Global preference persistence.
  final SettingsStore settingsStore;

  /// Validator and storage transaction for selected EPUBs.
  final EpubImporter importer;

  /// Platform document-picker boundary.
  final EpubPicker picker;

  /// Shared native publication session.
  final ReadiumEngine engine;

  /// Current catalog snapshot rendered by the library.
  List<CatalogBook> books = [];

  /// Current global reading preferences.
  ReaderSettings settings = const ReaderSettings();

  /// Whether a serial multi-file import is active.
  bool importing = false;

  /// Number of candidates whose import attempt has completed.
  int importDone = 0;

  /// Total number of candidates in the active import batch.
  int importTotal = 0;
  Timer? _locatorSave;

  /// Creates the production dependency graph and restores persisted state.
  static Future<ReaderController> create() async {
    final store = await FileCatalogStore.create();
    final engine = FlureadiumEngine();
    final controller = ReaderController(
      catalogStore: store,
      settingsStore: PreferenceSettingsStore(),
      importer: EpubImporter(root: store.root, engine: engine),
      picker: NativeEpubPicker(),
      engine: engine,
    );
    await controller.initialize();
    return controller;
  }

  /// Loads the catalog and global preferences concurrently at startup.
  Future<void> initialize() async {
    final loaded = await Future.wait<Object>([
      catalogStore.load(),
      settingsStore.load(),
    ]);
    books = loaded[0] as List<CatalogBook>;
    settings = loaded[1] as ReaderSettings;
    notifyListeners();
  }

  /// Most recently opened book, used by the Continue reading card.
  CatalogBook? get currentBook {
    final recent = books.where((book) => book.lastOpenedAt != null).toList()
      ..sort((a, b) => b.lastOpenedAt!.compareTo(a.lastOpenedAt!));
    return recent.firstOrNull;
  }

  /// Picks files and imports them serially.
  ///
  /// Flureadium owns one native publication session, so overlapping imports
  /// could close or replace the publication another import is inspecting.
  Future<List<ImportResult>> pickAndImport() async {
    final candidates = await picker.pick();
    if (candidates.isEmpty) return [];
    importing = true;
    importDone = 0;
    importTotal = candidates.length;
    notifyListeners();
    final results = <ImportResult>[];
    final hashes = books.map((book) => book.hash).toSet();
    for (final candidate in candidates) {
      final imported = await importer.import(candidate, hashes);
      results.add(imported.result);
      if (imported.book != null) {
        books = [...books, imported.book!];
        hashes.add(imported.book!.hash);
        await catalogStore.save(books);
      }
      importDone++;
      notifyListeners();
    }
    importing = false;
    notifyListeners();
    return results;
  }

  /// Records recent activity before navigation enters the reader.
  Future<void> markOpened(CatalogBook book) async {
    _replace(book.copyWith(lastOpenedAt: DateTime.now()));
    await catalogStore.save(books);
  }

  /// Updates the complete durable locator and debounces catalog writes.
  ///
  /// Readium may emit locators rapidly while scrolling. The in-memory state is
  /// updated immediately while disk writes are coalesced into one operation.
  Future<void> saveLocator(CatalogBook book, Locator locator) async {
    final current = books.firstWhere(
      (item) => item.hash == book.hash,
      orElse: () => book,
    );
    final progress = (locator.locations?.totalProgression ?? current.progress)
        .clamp(0.0, 1.0);
    _replace(
      current.copyWith(
        lastLocator: locator.toJson(),
        progress: progress,
        lastOpenedAt: DateTime.now(),
      ),
    );
    _locatorSave?.cancel();
    _locatorSave = Timer(const Duration(milliseconds: 500), () {
      catalogStore.save(books);
    });
  }

  /// Forces pending reading state to disk during lifecycle transitions.
  Future<void> flush() async {
    _locatorSave?.cancel();
    await catalogStore.save(books);
  }

  /// Removes both the catalog record and its private on-disk directory.
  Future<void> delete(CatalogBook book) async {
    books = books.where((item) => item.hash != book.hash).toList();
    await catalogStore.save(books);
    await catalogStore.deleteFiles(book);
    notifyListeners();
  }

  /// Applies and persists any supplied reader-wide preference values.
  Future<void> configure({
    ReadingMode? mode,
    ReadingTheme? theme,
    int? fontSize,
    bool? serif,
  }) async {
    settings = settings.copyWith(
      mode: mode,
      theme: theme,
      fontSize: fontSize,
      serif: serif,
    );
    notifyListeners();
    await settingsStore.save(settings);
  }

  void _replace(CatalogBook updated) {
    books = books
        .map((book) => book.hash == updated.hash ? updated : book)
        .toList();
    notifyListeners();
  }

  @override
  void dispose() {
    _locatorSave?.cancel();
    super.dispose();
  }
}

/// Minimal nullable-first helper used without adding a collection dependency.
extension FirstOrNull<T> on Iterable<T> {
  /// Returns the first item, or `null` when this iterable is empty.
  T? get firstOrNull => isEmpty ? null : first;
}
