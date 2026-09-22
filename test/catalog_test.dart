import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flureadium/flureadium.dart';
import 'package:reader/epub_service.dart';
import 'package:reader/models.dart';
import 'package:reader/storage.dart';

import 'fakes.dart';

void main() {
  test('catalog records preserve locator, metadata, and progress', () {
    final original = testBook(
      locator: {
        'href': 'chapter.xhtml',
        'type': 'application/xhtml+xml',
        'locations': {'totalProgression': .42, 'position': 4},
      },
    );
    final restored = CatalogBook.fromJson(original.toJson());
    expect(restored.title, original.title);
    expect(restored.authorLine, 'Test Author');
    expect(restored.progress, .42);
    expect(restored.lastLocator, original.lastLocator);
  });

  test('file catalog recovers a valid temporary atomic write', () async {
    final root = await Directory.systemTemp.createTemp('catalog_recovery');
    addTearDown(() => root.delete(recursive: true));
    final store = FileCatalogStore(root);
    final bookFile = File('${root.path}/books/a/book.epub');
    await bookFile.parent.create(recursive: true);
    await bookFile.writeAsBytes([1]);
    final book = CatalogBook(
      hash: 'a',
      fileName: 'a.epub',
      path: bookFile.path,
      title: 'A',
      authors: const [],
      addedAt: DateTime.utc(2026),
    );
    await File('${root.path}/catalog.json').writeAsString('{broken');
    await File('${root.path}/catalog.json.tmp').writeAsString(
      jsonEncode({
        'version': 1,
        'books': [book.toJson()],
      }),
    );
    final recovered = await store.load();
    expect(recovered.single.title, 'A');
    expect(
      jsonDecode(await File('${root.path}/catalog.json').readAsString()),
      isA<Map>(),
    );
  });

  test('deleting a catalog book removes its private book directory', () async {
    final root = await Directory.systemTemp.createTemp('catalog_delete');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final store = FileCatalogStore(root);
    final file = File('${root.path}/books/hash/book.epub');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1]);
    final book = CatalogBook(
      hash: 'hash',
      fileName: 'book.epub',
      path: file.path,
      title: 'Book',
      authors: const [],
      addedAt: DateTime.utc(2026),
    );
    await store.deleteFiles(book);
    expect(await file.parent.exists(), isFalse);
  });

  test(
    'import hashes files, applies fallbacks, and finds duplicates',
    () async {
      final root = await Directory.systemTemp.createTemp('epub_import');
      addTearDown(() => root.delete(recursive: true));
      final publication = Publication(
        metadata: Metadata(localizedTitle: LocalizedString.fromString('')),
        readingOrder: const [
          Link(href: 'one.xhtml', type: 'application/xhtml+xml'),
        ],
      );
      final importer = EpubImporter(
        root: root,
        engine: FakeEngine(publication),
      );
      final candidate = ImportCandidate(
        name: 'Fallback Title.epub',
        size: 4,
        readBytes: () async => Uint8List.fromList([1, 2, 3, 4]),
      );
      final first = await importer.import(candidate, {});
      expect(first.result.status, ImportStatus.imported);
      expect(first.book!.title, 'Fallback Title');
      expect(first.book!.authorLine, 'Unknown author');
      expect(await File(first.book!.path).exists(), isTrue);
      final duplicate = await importer.import(candidate, {first.book!.hash});
      expect(duplicate.result.status, ImportStatus.duplicate);
    },
  );

  test(
    'unsupported fixed, scripted, remote, and oversized books fail cleanly',
    () async {
      final root = await Directory.systemTemp.createTemp('epub_reject');
      addTearDown(() => root.delete(recursive: true));
      Future<ImportResult> attempt(
        Publication publication, {
        int size = 1,
      }) async {
        final importer = EpubImporter(
          root: root,
          engine: FakeEngine(publication),
        );
        return (await importer.import(
          ImportCandidate(
            name: 'bad.epub',
            size: size,
            readBytes: () async => Uint8List(1),
          ),
          {},
        )).result;
      }

      expect(
        (await attempt(
          testPublication(
            rendition: const Presentation(layout: EpubLayout.fixed),
          ),
        )).status,
        ImportStatus.failed,
      );
      expect(
        (await attempt(
          testPublication(
            readingOrder: const [
              Link(
                href: 'one.xhtml',
                type: 'application/xhtml+xml',
                properties: Properties(contains: ['scripted']),
              ),
            ],
          ),
        )).status,
        ImportStatus.failed,
      );
      expect(
        (await attempt(
          testPublication(
            readingOrder: const [
              Link(
                href: 'https://example.com/one.xhtml',
                type: 'application/xhtml+xml',
              ),
            ],
          ),
        )).status,
        ImportStatus.failed,
      );
      expect(
        (await attempt(testPublication(), size: maxEpubBytes + 1)).status,
        ImportStatus.failed,
      );
      expect(
        Directory('${root.path}/books').listSync().whereType<Directory>(),
        isEmpty,
      );
    },
  );

  test(
    'controller imports selected files sequentially and reports each result',
    () async {
      final root = await Directory.systemTemp.createTemp('multi_import');
      addTearDown(() => root.delete(recursive: true));
      final bytes = Uint8List.fromList([1, 2, 3]);
      final controller = await testController(
        root: root,
        files: [
          ImportCandidate(
            name: 'one.epub',
            size: 3,
            readBytes: () async => bytes,
          ),
          ImportCandidate(
            name: 'copy.epub',
            size: 3,
            readBytes: () async => bytes,
          ),
        ],
      );
      addTearDown(controller.dispose);
      final results = await controller.pickAndImport();
      expect(results.map((result) => result.status), [
        ImportStatus.imported,
        ImportStatus.duplicate,
      ]);
      expect(controller.books, hasLength(1));
      expect(controller.importDone, 2);
    },
  );

  test(
    'locator progress and settings persist through the controller',
    () async {
      final book = testBook();
      final controller = await testController(books: [book]);
      addTearDown(controller.dispose);
      const locator = Locator(
        href: 'chapter.xhtml',
        type: 'application/xhtml+xml',
        locations: Locations(totalProgression: .7),
      );
      await controller.saveLocator(book, locator);
      await controller.configure(
        mode: ReadingMode.pages,
        theme: ReadingTheme.dark,
        fontSize: 140,
        serif: false,
      );
      await controller.flush();
      expect(controller.books.single.progress, .7);
      expect(controller.books.single.lastLocator, locator.toJson());
      expect(controller.settings.mode, ReadingMode.pages);
      expect(controller.settings.theme, ReadingTheme.dark);
    },
  );
}
