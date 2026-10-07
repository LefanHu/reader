import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/book_service.dart';
import 'package:reader/illustrations/outbox.dart';
import 'package:reader/models.dart';
import 'package:reader/storage.dart';
import 'package:reader/text/document.dart';

import 'fakes.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('text_catalog');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<CatalogBook> importTxt([
    String text = 'First paragraph.\n\nSecond paragraph.',
  ]) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    final outcome = await BookImporter(root: root).import(
      ImportCandidate(
        name: 'Novel.txt',
        size: bytes.length,
        readBytes: () async => bytes,
      ),
      {},
    );
    expect(outcome.result.status, ImportStatus.imported);
    return outcome.book!;
  }

  test('catalog preserves complete text positions and metadata', () {
    final original = testBook(
      position: const TextPosition(sectionId: 's0', blockId: 'p0', offset: 2),
      progress: .42,
    );
    final restored = CatalogBook.fromJson(original.toJson());
    expect(restored.lastPosition, original.lastPosition);
    expect(restored.progress, .42);
    expect(restored.authorLine, 'Test Author');
  });

  test('catalog recovers a valid temporary generation and serializes saves across instances', () async {
    final book = await importTxt();
    await File('${root.path}/catalog.json').writeAsString('{broken');
    await File('${root.path}/catalog.json.tmp').writeAsString(
      jsonEncode({
        'version': 2,
        'books': [book.toJson()],
      }),
    );
    final store = FileCatalogStore(root);
    expect((await store.load()).single.hash, book.hash);
    await Future.wait([
      store.save([book]),
      FileCatalogStore(root).save([]),
      store.save([book.copyWith(progress: .7)]),
    ]);
    expect((await store.load()).single.progress, .7);
  });

  test(
    'legacy reset queues cloud deletions before removing owned book files',
    () async {
      final book = await importTxt();
      final directory = File(book.path).parent;
      await Directory('${directory.path}/visuals').create();
      await File('${directory.path}/visuals/manifest.json').writeAsString(
        jsonEncode({
          'profile': {'cloudBookId': 'old-cloud'},
        }),
      );
      await File('${root.path}/catalog.json').writeAsString(
        jsonEncode({
          'version': 1,
          'books': [book.toJson()],
        }),
      );
      final narration = Directory('${directory.path}/narration');
      await narration.create();
      await File('${narration.path}/manifest.json.tmp')
          .writeAsString(jsonEncode({'cloudBookId': 'c' * 64}));
      final narrationOutbox = FileIllustrationDeletionOutbox(
        root,
        fileName: 'narration-deletions.json',
      );
      final outbox = FileIllustrationDeletionOutbox(root);
      await outbox.enqueue('already-pending');
      final store = FileCatalogStore(root);
      expect(await store.load(), isEmpty);
      expect(await directory.exists(), isFalse);
      expect((await narrationOutbox.load()).single.cloudBookId, 'c' * 64);
      expect(
        (await outbox.load()).map((item) => item.cloudBookId),
        containsAll(['old-cloud', 'already-pending']),
      );
      expect(
        jsonDecode(
          await File('${root.path}/catalog.json').readAsString(),
        )['version'],
        2,
      );
      expect(await store.load(), isEmpty);
    },
  );

  test(
    'reset resumes after new catalog commits but before directory cleanup',
    () async {
      final book = await importTxt();
      await File('${root.path}/legacy-reset.json').writeAsString(
        jsonEncode({
          'hashes': [book.hash, '../outside'],
        }),
      );
      await FileCatalogStore(root).save([]);
      expect(await FileCatalogStore(root).load(), isEmpty);
      expect(await File(book.path).exists(), isFalse);
      expect(await File('${root.path}/legacy-reset.json').exists(), isFalse);
    },
  );

  test(
    'catalog deletion refuses paths and symlinks outside owned storage',
    () async {
      final outside = await Directory.systemTemp.createTemp('outside_reader');
      addTearDown(() => outside.delete(recursive: true));
      final file = File('${outside.path}/book.txt');
      await file.writeAsString('Keep me');
      final book = CatalogBook(
        hash: 'b' * 64,
        fileName: 'book.txt',
        path: file.path,
        title: 'Book',
        authors: const [],
        addedAt: DateTime.utc(2026),
      );
      final store = FileCatalogStore(root);
      await expectLater(store.deleteFiles(book), throwsFormatException);
      await Directory('${root.path}/books').create();
      await Link('${root.path}/books/${book.hash}').create(outside.path);
      final linked = CatalogBook(
        hash: book.hash,
        fileName: book.fileName,
        path: '${root.path}/books/${book.hash}/book.txt',
        title: book.title,
        authors: book.authors,
        addedAt: book.addedAt,
      );
      await expectLater(store.deleteFiles(linked), throwsFormatException);
      expect(await store.load(), isEmpty);
      expect(await file.readAsString(), 'Keep me');
    },
  );

  test(
    'import stages normalized sections and deduplicates identical bytes',
    () async {
      final book = await importTxt();
      final document = await TextDocumentStore().load(book.path);
      final section = await TextDocumentStore().loadSection(
        book.path,
        document.sections.first.id,
      );
      expect(section.blocks.map((block) => block.text), [
        'First paragraph.',
        'Second paragraph.',
      ]);
      final bytes = await File(book.path).readAsBytes();
      final duplicate = await BookImporter(root: root).import(
        ImportCandidate(
          name: 'Copy.txt',
          size: bytes.length,
          readBytes: () async => bytes,
        ),
        {book.hash},
      );
      expect(duplicate.result.status, ImportStatus.duplicate);
      expect(book.title, 'Novel');
    },
  );

  test(
    'failed imports remove staging and controller clears its busy state',
    () async {
      final controller = await testController(
        root: root,
        files: [
          ImportCandidate(
            name: 'Broken.epub',
            size: 2,
            readBytes: () async => Uint8List.fromList([1, 2]),
          ),
        ],
      );
      addTearDown(controller.dispose);
      final results = await controller.pickAndImport();
      expect(results.single.status, ImportStatus.failed);
      expect(controller.importing, isFalse);
      expect(controller.books, isEmpty);
      expect(Directory('${root.path}/books').listSync(), isEmpty);
    },
  );

  test(
    'controller persists positions and global typography independently',
    () async {
      final book = testBook();
      final controller = await testController(books: [book]);
      addTearDown(controller.dispose);
      const position = TextPosition(sectionId: 's0', blockId: 'p0', offset: 4);
      await controller.savePosition(book, position, .7);
      await controller.configure(
        mode: ReadingMode.pages,
        theme: ReadingTheme.dark,
        fontSize: 140,
        serif: false,
      );
      await controller.flush();
      expect(controller.books.single.lastPosition, position);
      expect(controller.books.single.progress, .7);
      expect(controller.settings.mode, ReadingMode.pages);
    },
  );
}
