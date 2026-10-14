import 'package:flutter/material.dart';

import '../catalog/catalog_book.dart';
import 'counts.dart';

/// Reading totals derived from the local catalog; never needs the network.
class LibrarySummary {
  /// Prefer [LibrarySummary.of]; the fields are plain totals.
  const LibrarySummary({
    required this.books,
    required this.finished,
    required this.wordsRead,
  });

  /// Totals [books]; words read is each book's progress share of its words.
  factory LibrarySummary.of(Iterable<CatalogBook> books) {
    var count = 0, finished = 0, words = 0;
    for (final book in books) {
      count++;
      if (book.finished) {
        finished++;
        words += book.wordCount;
      } else {
        words += (book.progress.clamp(0, 1) * book.wordCount).round();
      }
    }
    return LibrarySummary(books: count, finished: finished, wordsRead: words);
  }

  /// Books in the library on this device.
  final int books;

  /// Books read to the end.
  final int finished;

  /// Approximate words read, from saved progress rather than tracked time.
  final int wordsRead;
}

/// Headline serif figures for a [LibrarySummary]; wraps at large text sizes.
class LibrarySummaryFigures extends StatelessWidget {
  /// Renders [summary] without reading the catalog itself.
  const LibrarySummaryFigures({super.key, required this.summary});

  /// Totals to display.
  final LibrarySummary summary;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 40,
    runSpacing: 20,
    children: [
      _Figure(
        value: '${summary.books}',
        label: summary.books == 1 ? 'book' : 'books',
      ),
      _Figure(value: '${summary.finished}', label: 'finished'),
      _Figure(value: compactCount(summary.wordsRead), label: 'words read'),
    ],
  );
}

class _Figure extends StatelessWidget {
  const _Figure({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              fontFamily: 'Lora',
              fontSize: 40,
              height: 1.1,
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface,
            ),
          ),
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
