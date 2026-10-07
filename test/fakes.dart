import 'dart:io';
import 'dart:typed_data';

import 'package:reader/text/document.dart';
import 'package:reader/controller.dart';
import 'package:reader/book_service.dart';
import 'package:reader/illustrations/api.dart';
import 'package:reader/illustrations/indexer.dart';
import 'package:reader/illustrations/models.dart';
import 'package:reader/illustrations/store.dart';
import 'package:reader/models.dart';
import 'package:reader/storage.dart';

/// In-memory normalized document store for real viewport widget tests.
class MemoryDocumentStore extends TextDocumentStore {
  MemoryDocumentStore({List<TextSection>? sections, this.contents})
    : sections =
          sections ??
          [
            const TextSection(
              id: 's0',
              blocks: [
                TextBlock(id: 'p0', text: 'A test paragraph.'),
                TextBlock(id: 'p1', text: 'A second paragraph.'),
              ],
            ),
          ];
  final List<TextSection> sections;
  final List<TextContentsEntry>? contents;
  TextDocument get document => TextDocument(
    title: 'Test Book',
    authors: const ['Test Author'],
    sections: [
      for (final section in sections)
        SectionSummary(
          id: section.id,
          title: 'Section ${sections.indexOf(section) + 1}',
          source: section.id,
          length: section.length,
        ),
    ],
    contents:
        contents ??
        [
          for (final section in sections)
            TextContentsEntry(title: section.id, position: section.start),
        ],
  );
  @override
  Future<TextDocument> load(String sourcePath) async => document;
  @override
  Future<TextSection> loadSection(String sourcePath, String id) async =>
      sections.firstWhere((section) => section.id == id);
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
class FakePicker implements BookPicker {
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
class FakeTextIndexer implements TextIndexer {
  FakeTextIndexer({this.chapters = _defaultChapters});

  final List<ChapterTextIndex> chapters;

  static const _defaultChapters = [
    ChapterTextIndex(
      href: 's0',
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
    required String sourcePath,
    required String bookHash,
  }) async => BookTextIndex(bookHash: bookHash, chapters: chapters);
}

/// Offline illustration API used by tests that do not exercise cloud setup.
class FakeIllustrationApi implements IllustrationApi {
  FakeIllustrationApi({this.configured = false});

  @override
  final bool configured;
  bool session = true;
  @override
  Future<void> signIn() async => session = true;
  final deletedBooks = <String>[];
  @override
  Future<bool> hasSession() async => session;
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
  Future<void> deleteBook(String cloudBookId, {bool interactive = true}) async {
    deletedBooks.add(cloudBookId);
  }

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
  SettingsStore? settingsStore,
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
    illustrationApi: FakeIllustrationApi(),
  );
  await controller.initialize();
  return controller;
}

/// Builds a catalog fixture at an optional normalized text position.
CatalogBook testBook({TextPosition? position, double progress = 0}) =>
    CatalogBook(
      hash: 'a' * 64,
      fileName: 'test.txt',
      path: '/tmp/test.txt',
      title: 'Test Book',
      authors: const ['Test Author'],
      addedAt: DateTime.utc(2026),
      lastPosition: position,
      progress: progress,
    );
