import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flureadium/flureadium.dart';

import 'epub_service.dart';
import 'models.dart';
import 'storage.dart';

class ReaderController extends ChangeNotifier {
  ReaderController({
    required this.catalogStore,
    required this.settingsStore,
    required this.importer,
    required this.picker,
    required this.engine,
  });

  final CatalogStore catalogStore;
  final SettingsStore settingsStore;
  final EpubImporter importer;
  final EpubPicker picker;
  final ReadiumEngine engine;

  List<CatalogBook> books = [];
  ReaderSettings settings = const ReaderSettings();
  bool importing = false;
  int importDone = 0;
  int importTotal = 0;
  Timer? _locatorSave;

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

  Future<void> initialize() async {
    final loaded = await Future.wait<Object>([
      catalogStore.load(),
      settingsStore.load(),
    ]);
    books = loaded[0] as List<CatalogBook>;
    settings = loaded[1] as ReaderSettings;
    notifyListeners();
  }

  CatalogBook? get currentBook {
    final recent = books.where((book) => book.lastOpenedAt != null).toList()
      ..sort((a, b) => b.lastOpenedAt!.compareTo(a.lastOpenedAt!));
    return recent.firstOrNull;
  }

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

  Future<void> markOpened(CatalogBook book) async {
    _replace(book.copyWith(lastOpenedAt: DateTime.now()));
    await catalogStore.save(books);
  }

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

  Future<void> flush() async {
    _locatorSave?.cancel();
    await catalogStore.save(books);
  }

  Future<void> delete(CatalogBook book) async {
    books = books.where((item) => item.hash != book.hash).toList();
    await catalogStore.save(books);
    await catalogStore.deleteFiles(book);
    notifyListeners();
  }

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

extension FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
