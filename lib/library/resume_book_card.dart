import 'package:flutter/material.dart';

import '../catalog/catalog_book.dart';
import 'book_cover.dart';

/// A restrained resume action; its width does not stretch across desktop shelves.
class ResumeBookCard extends StatelessWidget {
  /// Creates this library component with its book or action inputs.
  const ResumeBookCard({super.key, required this.book, required this.onOpen});

  /// Book whose catalog metadata is presented.
  final CatalogBook book;

  /// Actions invoked when the book is opened or deleted.
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ExcludeSemantics(
              child: SizedBox(
                width: 40,
                height: 60,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: BookCover(book: book, thumbnail: true),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Continue reading',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${(book.progress * 100).round()}% read',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    ),
  );
}
