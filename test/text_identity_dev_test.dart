@Timeout(Duration(minutes: 2))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/identity/cloud_service_exception.dart';
import 'package:reader/illustrations/http_illustration_api.dart';
import 'package:reader/importing/book_importer.dart';
import 'package:reader/importing/import_candidate.dart';
import 'package:reader/text/document_store.dart';
import 'package:reader/text_identity/http_text_identity_api.dart';
import 'package:reader/text_identity/paragraph_fingerprints.dart';
import 'package:reader/text_identity/text_identity_api.dart';

import 'support/dev_api_books.dart';
import 'support/dev_api_client.dart';
import 'support/dev_api_environment.dart';
import 'support/dev_api_identity.dart';

void main() {
  late DevApiIdentity identity;
  late HttpTextIdentityApi api;
  late HttpIllustrationApi illustrations;

  setUpAll(() async => identity = await DevApiIdentity.shared());
  setUp(() {
    final client = DevApiClient.create();
    final baseUri = DevApiEnvironment.instance.baseUri;
    api = HttpTextIdentityApi(
      identity: identity,
      client: client,
      baseUri: baseUri,
    );
    illustrations = HttpIllustrationApi(
      identity: identity,
      client: client,
      baseUri: baseUri,
    );
  });

  test('a real EPUB resolves to one shared text across files and a different '
      'translation gets its own', () async {
    final (:book, :paragraphs, :sectionCount) = await _importStormOfSteel();
    expect(book.title, 'The Storm of Steel');
    expect(paragraphs.length, greaterThan(1000));

    Future<TextIdentityResult> identifyFresh(List<String> copy) async {
      final result = await api.identify(
        devBook(),
        _fingerprinted(copy, sectionCount),
      );
      deleteDevBookAfterTest(illustrations, result.cloudBookId);
      return result;
    }

    // The first run creates the shared text from this file; every later run
    // finds it by sketch. Either way the same fingerprints align completely.
    final first = await identifyFresh(paragraphs);
    expect(first.score, 1);
    final again = await identifyFresh(paragraphs);
    expect(again.textId, first.textId);
    expect(again.score, 1);

    // Another file of the same book: a watermark, extra front matter and
    // different typography still join the same text.
    final otherFile = await identifyFresh(_otherFile(paragraphs));
    expect(otherFile.textId, first.textId);
    expect(otherFile.score, greaterThanOrEqualTo(.9));
    expect(otherFile.score, lessThan(1));

    // A different translation shares no paragraph, so it is another text.
    final translation = await identifyFresh(_otherTranslation(paragraphs));
    expect(translation.textId, isNot(first.textId));
    expect(translation.score, 1);
  });

  test('malformed fingerprints are refused', () async {
    await expectLater(
      api.identify(
        devBook(),
        BookFingerprints(fingerprints: Uint8List(7), sectionCount: 1),
      ),
      throwsA(
        isA<CloudServiceException>().having(
          (error) => error.statusCode,
          'statusCode',
          400,
        ),
      ),
    );
  });
}

/// Imports `test/fixtures/books/the-storm-of-steel.epub` (Standard Ebooks,
/// public domain) through the real importer and reads its normalized blocks.
Future<({CatalogBook book, List<String> paragraphs, int sectionCount})>
_importStormOfSteel() async {
  final root = await Directory.systemTemp.createTemp('text_identity_dev_epub');
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

/// Fingerprints [paragraphs] as `buildBookFingerprints` does for a file.
BookFingerprints _fingerprinted(List<String> paragraphs, int sectionCount) {
  final fingerprints = BytesBuilder(copy: false);
  for (final paragraph in paragraphs) {
    fingerprints.add(paragraphFingerprint(paragraph));
  }
  return BookFingerprints(
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
