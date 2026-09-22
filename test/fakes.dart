import 'dart:io';
import 'dart:typed_data';

import 'package:flureadium/flureadium.dart';
import 'package:reader/controller.dart';
import 'package:reader/epub_service.dart';
import 'package:reader/illustrations/api.dart';
import 'package:reader/illustrations/indexer.dart';
import 'package:reader/illustrations/models.dart';
import 'package:reader/illustrations/store.dart';
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

/// Illustration sidecar store that keeps widget tests off the filesystem.
class MemoryIllustrationStore implements IllustrationStore {
  final Map<String, IllustrationManifest> manifests = {};
  final Map<String, BookTextIndex> indexes = {};
  final Map<String, Uint8List> images = {};

  @override
  Future<void> deleteSceneFiles(CatalogBook book, String sceneId) async {
    images.remove('$sceneId:image');
    images.remove('$sceneId:thumbnail');
  }

  @override
  Future<BookTextIndex?> loadIndex(CatalogBook book) async =>
      indexes[book.hash];

  @override
  Future<IllustrationManifest> loadManifest(CatalogBook book) async =>
      manifests[book.hash] ?? IllustrationManifest(bookHash: book.hash);

  @override
  Future<void> saveIndex(CatalogBook book, BookTextIndex index) async {
    indexes[book.hash] = index;
  }

  @override
  Future<String> saveImage(
    CatalogBook book,
    String sceneId,
    Uint8List bytes, {
    bool thumbnail = false,
  }) async {
    final key = '$sceneId:${thumbnail ? 'thumbnail' : 'image'}';
    images[key] = bytes;
    return '/memory/$key.webp';
  }

  @override
  Future<void> saveManifest(
    CatalogBook book,
    IllustrationManifest manifest,
  ) async {
    manifests[book.hash] = manifest;
  }
}

/// Stable one-chapter index used unless a test supplies its own indexer.
class FakeTextIndexer implements EpubTextIndexer {
  FakeTextIndexer({this.chapters = _defaultChapters});

  final List<ChapterTextIndex> chapters;

  static const _defaultChapters = [
    ChapterTextIndex(
      href: 'chapter.xhtml',
      spineOrdinal: 0,
      title: null,
      paragraphs: [
        IndexedParagraph(
          id: 'paragraph-1',
          text: 'A test paragraph.',
          cssSelector: 'body > p:nth-of-type(1)',
          ordinal: 0,
          progression: 1,
        ),
      ],
    ),
  ];

  @override
  Future<BookTextIndex> index({
    required String epubPath,
    required String bookHash,
  }) async => BookTextIndex(bookHash: bookHash, chapters: chapters);
}

/// Offline illustration API used by tests that do not exercise cloud setup.
class FakeIllustrationApi implements IllustrationApi {
  FakeIllustrationApi({this.configured = false});

  @override
  final bool configured;
  final List<int> createdChapterOrdinals = [];
  final List<String> unlockedSceneIds = [];
  final Map<String, IllustrationJobResult> jobResults = {};

  @override
  Future<void> confirmProfile(IllustrationProfile profile) async {}

  @override
  Future<String> createChapterJob({
    required IllustrationProfile profile,
    required ChapterTextIndex chapter,
  }) async {
    createdChapterOrdinals.add(chapter.spineOrdinal);
    return 'job-${chapter.spineOrdinal}';
  }

  @override
  Future<void> deleteBook(String cloudBookId) async {}

  @override
  Future<void> deleteAccount() async {}

  @override
  Future<void> deleteScene(String sceneId) async {}

  @override
  Future<IllustrationJobResult> getJob(String jobId) async =>
      jobResults[jobId] ??
      IllustrationJobResult(id: jobId, status: 'queued', scenes: const []);

  @override
  Future<IllustrationSetup> registerBook(
    CatalogBook book, {
    required int chapterCount,
  }) async => const IllustrationSetup(
    cloudBookId: 'cloud-book',
    suggestedStyle: 'Cinematic storybook realism',
    alternativeStyles: ['Expressive ink sketch'],
    estimatedCredits: 3,
  );

  @override
  Future<void> regenerateScene(String sceneId) async {}

  @override
  Future<void> signOut() async {}

  @override
  Future<UnlockedIllustration> unlockScene(String sceneId) async {
    unlockedSceneIds.add(sceneId);
    return UnlockedIllustration(
      image: Uint8List.fromList(const [1, 2, 3]),
      thumbnail: Uint8List.fromList(const [1, 2]),
      altText: 'A generated test scene',
      caption: 'A scene from the chapter',
      generationVersion: 1,
    );
  }
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
    illustrationStore: MemoryIllustrationStore(),
    textIndexer: FakeTextIndexer(),
    illustrationApi: FakeIllustrationApi(),
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
