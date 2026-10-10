import 'package:flutter/material.dart';

import '../catalog/catalog_book.dart';
import 'book_actions.dart';
import 'book_cover.dart';
import 'book_details.dart';
import 'book_progress.dart';

/// iOS uses a lazy, content-sized row even on wide iPads and at large text sizes.
class BookRow extends StatelessWidget {
  /// Creates this library component with its book or action inputs.
  const BookRow({
    super.key,
    required this.book,
    required this.onOpen,
    required this.onDelete,
  });

  /// Book whose catalog metadata is presented.
  final CatalogBook book;

  /// Actions invoked when the book is opened or deleted.
  final VoidCallback onOpen, onDelete;
  @override
  Widget build(BuildContext context) => Semantics(
    key: ValueKey('library-book-${book.hash}'),
    label: bookSemanticsLabel(book),
    button: true,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: SizedBox(
                  width: 64,
                  height: 96,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: BookCover(book: book, thumbnail: true),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    BookDetails(book: book),
                    const SizedBox(height: 12),
                    BookProgress(book: book),
                  ],
                ),
              ),
              BookActions(onDelete: onDelete),
            ],
          ),
        ),
      ),
    ),
  );
}
