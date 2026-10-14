@Timeout(Duration(minutes: 2))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/catalog_works/http_works_api.dart';
import 'package:reader/catalog_works/work_text.dart';
import 'package:reader/catalog_works/works_api.dart';
import 'package:reader/identity/cloud_service_exception.dart';
import 'package:reader/illustrations/http_illustration_api.dart';
import 'package:reader/importing/book_importer.dart';
import 'package:reader/importing/import_candidate.dart';
import 'package:reader/text/document_store.dart';

import 'support/dev_api_books.dart';
import 'support/dev_api_client.dart';
import 'support/dev_api_environment.dart';
import 'support/dev_api_identity.dart';

void main() {
  late DevApiIdentity identity;
  late HttpWorksApi api;
  late HttpIllustrationApi illustrations;

  setUpAll(() async => identity = await DevApiIdentity.shared());
  setUp(() {
    final client = DevApiClient.create();
    final baseUri = DevApiEnvironment.instance.baseUri;
    api = HttpWorksApi(identity: identity, client: client, baseUri: baseUri);
    illustrations = HttpIllustrationApi(
      identity: identity,
      client: client,
      baseUri: baseUri,
    );
  });

  test(
    'a real EPUB links to its Open Library work across files and a different '
    'translation is refused',
    () async {
      final (:book, :paragraphs, :sectionCount) = await _importStormOfSteel();
      expect(book.title, 'The Storm of Steel');
      expect(book.authors, contains('Ernst Jünger'));
      expect(paragraphs.length, greaterThan(1000));
      final text = _fingerprinted(paragraphs, sectionCount);

      final search = await api.search('Storm of Steel Jünger');
      expect(search.degraded, isFalse);
      final work = search.works.firstWhere(
        (work) =>
            work.title.toLowerCase().contains('storm of steel') &&
            work.author == 'Ernst Jünger',
      );

      Future<WorkLinkResult> linkFresh(WorkText copy) async {
        final result = await api.link(
          devBook(),
          copy,
          title: work.title,
          author: work.author,
          firstPublishYear: work.firstPublishYear,
        );
        deleteDevBookAfterTest(illustrations, result.cloudBookId);
        return result;
      }

      // The first run makes this file the work's reference; every later run
      // aligns with it. Either way the same fingerprints match completely, so
      // server and client agree on real text.
      final first = await linkFresh(text);
      expect(first.score, 1);
      expect(first.work.id, work.id);
      expect(first.work.linked, isTrue);
      expect((await linkFresh(text)).score, 1);

      // Another file of the same book: a watermark, extra front matter and
      // different typography still clear the threshold.
      final otherFile = await linkFresh(
        _fingerprinted(_otherFile(paragraphs), sectionCount),
      );
      expect(otherFile.score, greaterThanOrEqualTo(.9));
      expect(otherFile.score, lessThan(1));

      // A different translation shares no paragraph text.
      await expectLater(
        api.link(
          devBook(),
          _fingerprinted(_otherTranslation(paragraphs), sectionCount),
          title: work.title,
          author: work.author,
        ),
        throwsA(
          isA<CloudServiceException>()
              .having((error) => error.statusCode, 'statusCode', 422)
              .having((error) => error.message, 'message', contains('0%')),
        ),
      );
    },
  );

  test('search answers a bounded list of works', () async {
    final search = await api.search('zzqx unlikely title');
    expect(search.works.length, lessThanOrEqualTo(20));
  });

  test('an unlinked book has no work and unlinking it is idempotent', () async {
    final book = devBook();
    expect(await api.current(book), isNull);
    await api.unlink(book);
    expect(await api.current(book), isNull);
  });

  test('malformed fingerprints are refused and register nothing', () async {
    final book = devBook();
    await expectLater(
      api.link(
        book,
        WorkText(fingerprints: Uint8List(7), sectionCount: 1),
        title: 'zzqx unlikely title',
        author: '',
      ),
      throwsA(
        isA<CloudServiceException>().having(
          (error) => error.statusCode,
          'statusCode',
          400,
        ),
      ),
    );
    expect(await api.current(book), isNull);
  });
}

/// Imports `test/fixtures/books/the-storm-of-steel.epub` (Standard Ebooks,
/// public domain) through the real importer and reads its normalized blocks.
Future<({CatalogBook book, List<String> paragraphs, int sectionCount})>
_importStormOfSteel() async {
  final root = await Directory.systemTemp.createTemp('works_dev_epub');
  addTearDown(() => root.delete(recursive: true));
  final bytes = await File('test/fixtures/books/the-storm-of-steel.epub')
      .readAsBytes();
  final imported = await BookImporter(root: root).import(
    ImportCandidate(
      name: 'the-storm-of-steel.epub',
      size: bytes.length,
      readBytes: () async => bytes,
    ),
    {},
  );
  final book = imported.book!;
  final documents = InlineTextDocumentStore();
  final document = await documents.load(book.path);
  final paragraphs = <String>[];
  for (final section in document.sections) {
    final loaded = await documents.loadSection(book.path, section.id);
    paragraphs.addAll(loaded.blocks.map((block) => block.text));
  }
  return (
    book: book,
    paragraphs: paragraphs,
    sectionCount: document.sections.length,
  );
}

/// Fingerprints [paragraphs] as `buildWorkText` does for a file.
WorkText _fingerprinted(List<String> paragraphs, int sectionCount) {
  final fingerprints = BytesBuilder(copy: false);
  for (final paragraph in paragraphs) {
    fingerprints.add(workParagraphFingerprint(paragraph));
  }
  return WorkText(
    fingerprints: fingerprints.takeBytes(),
    sectionCount: sectionCount,
  );
}

/// [paragraphs] as a different file of the same edition would carry them.
List<String> _otherFile(List<String> paragraphs) {
  final typographic = [
    for (final (index, paragraph) in paragraphs.indexed)
      index.isEven
          ? paragraph.replaceAll('’', "'").replaceAll('—', ' -- ').toUpperCase()
          : paragraph,
  ];
  return [
    'This ebook was downloaded from an online library of public domain books.',
    'Transcribed and proofread by volunteers; any errors are our own.',
    ...typographic.take(typographic.length ~/ 2),
    'Watermarked copy licensed to a reader for personal use only, no resale.',
    ...typographic.skip(typographic.length ~/ 2),
  ];
}

/// [paragraphs] each worded differently, like another translation.
List<String> _otherTranslation(List<String> paragraphs) => [
  for (final paragraph in paragraphs) 'As the translator puts it, $paragraph',
];
