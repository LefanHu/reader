import 'package:flutter/material.dart';

import '../preferences/library_filter.dart';

/// Human-readable label shared by the sidebar and compact filter control.
String libraryFilterLabel(LibraryFilter value) => switch (value) {
  LibraryFilter.all => 'All books',
  LibraryFilter.reading => 'Reading',
  LibraryFilter.finished => 'Finished',
};

/// Fixed-width navigation shown when the library has tablet-class width.
class LibrarySidebar extends StatelessWidget {
  /// Creates this library component with its book or action inputs.
  const LibrarySidebar({
    super.key,
    required this.filter,
    required this.onFilter,
  });

  /// Current temporary catalog filter.
  final LibraryFilter filter;

  /// Invoked when a catalog filter is selected.
  final ValueChanged<LibraryFilter> onFilter;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 200,
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 30, 18, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Reader',
              style: TextStyle(
                fontFamily: 'Lora',
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 34),
            for (final value in LibraryFilter.values)
              ListTile(
                selected: filter == value,
                title: Text(libraryFilterLabel(value)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                onTap: () => onFilter(value),
              ),
          ],
        ),
      ),
    ),
  );
}
