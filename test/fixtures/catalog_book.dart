import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/importing/book_importer.dart';
import 'package:reader/importing/import_candidate.dart';
import 'package:reader/text/text_position.dart';

/// Builds a catalog fixture at an optional normalized text position;
/// [hash] defaults to a fixed value shared by local-only tests.
CatalogBook testBook({
  TextPosition? position,
  double progress = 0,
  String? hash,
}) => CatalogBook(
  hash: hash ?? 'a' * 64,
  fileName: 'test.txt',
  path: '/tmp/test.txt',
  title: 'Test Book',
  authors: const ['Test Author'],
  addedAt: DateTime.utc(2026),
  lastPosition: position,
  progress: progress,
);

/// Imports [prose] as a real TXT book under [root] with normalized sidecars.
Future<CatalogBook> importTextBook(
  Directory root,
  String prose, {
  String name = 'Book.txt',
}) async {
  final bytes = Uint8List.fromList(utf8.encode(prose));
  final outcome = await BookImporter(root: root).import(
    ImportCandidate(
      name: name,
      size: bytes.length,
      readBytes: () async => bytes,
    ),
    {},
  );
  final book = outcome.book;
  if (book == null) {
    throw StateError('Import failed: ${outcome.result.status}');
  }
  return book;
}
