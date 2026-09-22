import 'dart:io';

import 'package:flureadium/flureadium.dart';
import 'package:reader/controller.dart';
import 'package:reader/epub_service.dart';
import 'package:reader/models.dart';
import 'package:reader/storage.dart';

/// Builds the smallest publication needed by importer and reader tests.
Publication testPublication({
  String title = 'Test Book',
  List<Link> toc = const [],
  Presentation? rendition,
  List<Link>? readingOrder,
}) => Publication(
  metadata: Metadata(
    localizedTitle: LocalizedString.fromString(title),
    authors: [Contributor.fromString('Test Author')],
    languages: const ['en'],
    rendition: rendition,
  ),
  readingOrder:
      readingOrder ??
      const [Link(href: 'chapter.xhtml', type: 'application/xhtml+xml')],
  tableOfContents: toc,
);

/// In-memory Readium adapter that records commands without native channels.
class FakeEngine implements ReadiumEngine {
  FakeEngine(this.publication);
  final Publication publication;
  EPUBPreferences? defaults;
  EPUBPreferences? preferences;
  Link? visitedLink;
  int closeCount = 0;

  @override
  Future<Publication> load(String path) async => publication;
  @override
  Future<Publication> open(String path) async => publication;
  @override
  Future<void> close() async => closeCount++;
  @override
  void setDefaults(EPUBPreferences value) => defaults = value;
  @override
  Future<void> setPreferences(EPUBPreferences value) async =>
      preferences = value;
  @override
  Future<bool> goByLink(Link link, Publication publication) async {
    visitedLink = link;
    return true;
  }

  @override
  Future<void> nextChapter() async {}
  @override
  Future<void> goLeft() async {}
  @override
  Future<void> previousChapter() async {}
  @override
  Future<void> goRight() async {}
}

/// Catalog store used to verify controller behavior without filesystem I/O.
class MemoryCatalogStore implements CatalogStore {
  MemoryCatalogStore([List<CatalogBook> initial = const []])
    : books = List.of(initial);
  List<CatalogBook> books;
  final List<CatalogBook> deleted = [];
  @override
  Future<List<CatalogBook>> load() async => List.of(books);
  @override
  Future<void> save(List<CatalogBook> value) async => books = List.of(value);
  @override
  Future<void> deleteFiles(CatalogBook book) async => deleted.add(book);
}

/// Preference store that exposes the last persisted value to assertions.
class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([this.settings = const ReaderSettings()]);
  ReaderSettings settings;
  @override
  Future<ReaderSettings> load() async => settings;
  @override
  Future<void> save(ReaderSettings value) async => settings = value;
}

/// Deterministic picker whose selected files are supplied by each test.
class FakePicker implements EpubPicker {
  FakePicker([this.files = const []]);
  List<ImportCandidate> files;
  @override
  Future<List<ImportCandidate>> pick() async => files;
}

/// Creates an initialized controller with replaceable in-memory dependencies.
Future<ReaderController> testController({
  List<CatalogBook> books = const [],
  List<ImportCandidate> files = const [],
  Publication? publication,
  Directory? root,
}) async {
  final engine = FakeEngine(publication ?? testPublication());
  final directory =
      root ?? Directory('${Directory.systemTemp.path}/reader_test');
  final controller = ReaderController(
    catalogStore: MemoryCatalogStore(books),
    settingsStore: MemorySettingsStore(),
    importer: EpubImporter(root: directory, engine: engine),
    picker: FakePicker(files),
    engine: engine,
  );
  await controller.initialize();
  return controller;
}

/// Builds a stable catalog fixture, optionally at a saved Readium locator.
CatalogBook testBook({Map<String, dynamic>? locator}) => CatalogBook(
  hash: 'abc123',
  fileName: 'test.epub',
  path: '/tmp/test.epub',
  title: 'Test Book',
  authors: const ['Test Author'],
  addedAt: DateTime.utc(2026),
  lastLocator: locator,
  progress:
      ((locator?['locations'] as Map?)?['totalProgression'] as num?)
          ?.toDouble() ??
      0,
);
