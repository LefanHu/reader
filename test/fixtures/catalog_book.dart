import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/text/text_position.dart';

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
