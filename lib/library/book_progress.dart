import 'package:flutter/material.dart';

import '../catalog/catalog_book.dart';

/// Progress stays visible without desktop metadata and shares the app palette.
class BookProgress extends StatelessWidget {
  /// Creates this library component with its book or action inputs.
  const BookProgress({super.key, required this.book});

  /// Book whose catalog metadata is presented.
  final CatalogBook book;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: LinearProgressIndicator(
      value: book.progress,
      minHeight: 3,
      backgroundColor: Theme.of(context).colorScheme.outlineVariant,
      color: Theme.of(context).colorScheme.primary,
    ),
  );
}
