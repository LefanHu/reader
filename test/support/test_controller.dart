import 'dart:io';

import 'package:reader/app/reader_controller.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/importing/book_importer.dart';
import 'package:reader/importing/import_candidate.dart';
import 'package:reader/preferences/settings_store.dart';
import 'package:reader/text/book_word_counter.dart';

import 'memory_catalog_store.dart';
import 'memory_settings_store.dart';
import 'fake_picker.dart';
import 'memory_illustration_store.dart';
import 'fake_text_indexer.dart';
import 'fake_word_counter.dart';
import 'fake_illustration_api.dart';

/// Creates an initialized controller with replaceable in-memory dependencies.
Future<ReaderController> testController({
  List<CatalogBook> books = const [],
  List<ImportCandidate> files = const [],
  SettingsStore? settingsStore,
  BookWordCounter? wordCounter,
  Directory? root,
}) async {
  final directory =
      root ?? Directory('${Directory.systemTemp.path}/reader_test');
  final controller = ReaderController(
    catalogStore: MemoryCatalogStore(books),
    settingsStore: settingsStore ?? MemorySettingsStore(),
    importer: BookImporter(root: directory),
    picker: FakePicker(files),
    illustrationStore: MemoryIllustrationStore(),
    textIndexer: FakeTextIndexer(),
    wordCounter: wordCounter ?? FakeWordCounter(),
    illustrationApi: FakeIllustrationApi(),
  );
  await controller.initialize();
  return controller;
}
