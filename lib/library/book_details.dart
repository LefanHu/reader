import 'package:flutter/material.dart';

import '../catalog/catalog_book.dart';
import '../text/word_count_label.dart';

/// Shared metadata remains available to assistive technology without hover.
String bookSemanticsLabel(CatalogBook book) => [
  book.title,
  book.authorLine,
  if (book.wordCount != null) 'Approximately ${book.wordCount} words',
  '${(book.progress * 100).round()}% read',
].join(', ');

/// Metadata uses content-driven heights in lists and a scrollable cover overlay.
class BookDetails extends StatelessWidget {
  /// Creates this library component with its book or action inputs.
  const BookDetails({super.key, required this.book});

  /// Book whose catalog metadata is presented.
  final CatalogBook book;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          book.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: 'Lora',
            fontSize: 18,
            height: 1.3,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          book.authorLine,
          style: TextStyle(
            fontSize: 14,
            height: 1.4,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (book.wordCount != null) ...[
          const SizedBox(height: 6),
          Text(
            wordCountLabel(book.wordCount!),
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    ),
  );
}
