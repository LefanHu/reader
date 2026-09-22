import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'models.dart';
import 'reader.dart';
import 'theme.dart';

/// Adaptive catalog for importing, finding, opening, and deleting EPUBs.
class LibraryScreen extends StatefulWidget {
  /// Creates the catalog bound to the shared [controller].
  const LibraryScreen({super.key, required this.controller});

  /// Source of catalog data, import progress, and mutations.
  final ReaderController controller;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  LibraryFilter filter = LibraryFilter.all;
  LibrarySort sort = LibrarySort.recent;
  String query = '';

  Future<void> _import() async {
    // Flureadium declares macOS support but its current macOS plugin is only a
    // template stub. Guard the call so users see an explanation instead of a
    // MissingPluginException from loadPublication.
    if (Platform.isMacOS) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Use the iOS app to import EPUBs'),
          content: const Text(
            'Flureadium 0.19.3 does not implement publication loading in its macOS plugin. Run Reader on an iPhone or iPad simulator or device to import and read EPUBs.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      );
      return;
    }
    List<ImportResult> results;
    try {
      results = await widget.controller.pickAndImport();
    } on PlatformException catch (error) {
      if (!mounted) return;
      final message = error.code == 'ENTITLEMENT_NOT_FOUND'
          ? 'The app does not have permission to read selected files. Rebuild the app and try again.'
          : 'The file picker could not be opened: ${error.message ?? error.code}';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    if (!mounted || results.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import results'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: results
                .map(
                  (result) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(switch (result.status) {
                      ImportStatus.imported => Icons.check_circle_outline,
                      ImportStatus.duplicate => Icons.content_copy,
                      ImportStatus.failed => Icons.error_outline,
                    }),
                    title: Text(result.fileName),
                    subtitle: Text(
                      result.message ??
                          switch (result.status) {
                            ImportStatus.imported => 'Imported',
                            ImportStatus.duplicate => 'Duplicate',
                            ImportStatus.failed => 'Failed',
                          },
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _open(CatalogBook book) async {
    await widget.controller.markOpened(book);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(book: book, controller: widget.controller),
      ),
    );
  }

  Future<void> _delete(CatalogBook book) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete book?'),
        content: Text('Remove “${book.title}” and its saved reading position?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes == true) await widget.controller.delete(book);
  }

  List<CatalogBook> _visible() {
    final normalized = query.trim().toLowerCase();
    final books = widget.controller.books.where((book) {
      final matches = '${book.title} ${book.authorLine}'.toLowerCase().contains(
        normalized,
      );
      return matches &&
          switch (filter) {
            LibraryFilter.all => true,
            LibraryFilter.reading => book.started && !book.finished,
            LibraryFilter.finished => book.finished,
          };
    }).toList();
    books.sort((a, b) {
      if (sort == LibrarySort.title) {
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      }
      return (b.lastOpenedAt ?? b.addedAt).compareTo(
        a.lastOpenedAt ?? a.addedAt,
      );
    });
    return books;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        // Use actual window width so iPad split view gets the compact layout.
        final wide = constraints.maxWidth >= 700;
        return Scaffold(
          body: SafeArea(
            child: Stack(
              children: [
                Row(
                  children: [
                    if (wide)
                      _Sidebar(
                        filter: filter,
                        onFilter: (value) => setState(() => filter = value),
                      ),
                    Expanded(child: _content(wide)),
                  ],
                ),
                if (widget.controller.importing)
                  // Block overlapping picker/import actions while Readium owns
                  // the single native publication session.
                  ColoredBox(
                    color: Colors.black38,
                    child: Center(
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: Semantics(
                            liveRegion: true,
                            label:
                                'Importing ${widget.controller.importDone + 1} of ${widget.controller.importTotal}',
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(),
                                const SizedBox(height: 16),
                                Text(
                                  'Importing ${widget.controller.importDone + 1} of ${widget.controller.importTotal}',
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );

  Widget _content(bool wide) {
    final visible = _visible();
    final current = widget.controller.currentBook;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final horizontal = wide ? 42.0 : 20.0;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(horizontal, 24, horizontal, 12),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Your library',
                        style: Theme.of(context).textTheme.headlineLarge
                            ?.copyWith(
                              fontFamily: 'Lora',
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Open source licenses',
                      onPressed: () => showLicensePage(
                        context: context,
                        applicationName: 'Reader',
                        applicationLegalese: 'EPUB rendering uses Flureadium and the Readium toolkits.',
                      ),
                      icon: const Icon(Icons.info_outline),
                    ),
                    if (wide)
                      FilledButton.icon(
                        onPressed: _import,
                        icon: const Icon(Icons.add),
                        label: const Text('Import EPUBs'),
                      )
                    else
                      IconButton.filled(
                        tooltip: 'Import EPUBs',
                        onPressed: _import,
                        icon: const Icon(Icons.add),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                TextField(
                  onChanged: (value) => setState(() => query = value),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search title or author',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (!wide)
                      Expanded(
                        child: DropdownButtonFormField<LibraryFilter>(
                          initialValue: filter,
                          decoration: const InputDecoration(
                            labelText: 'Filter',
                            border: OutlineInputBorder(),
                          ),
                          items: LibraryFilter.values
                              .map(
                                (value) => DropdownMenuItem(
                                  value: value,
                                  child: Text(_filterName(value)),
                                ),
                              )
                              .toList(),
                          onChanged: (value) => setState(() => filter = value!),
                        ),
                      ),
                    if (!wide) const SizedBox(width: 12),
                    PopupMenuButton<LibrarySort>(
                      tooltip: 'Sort books',
                      initialValue: sort,
                      onSelected: (value) => setState(() => sort = value),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: LibrarySort.recent,
                          child: Text('Recent activity'),
                        ),
                        PopupMenuItem(
                          value: LibrarySort.title,
                          child: Text('Title A–Z'),
                        ),
                      ],
                      child: const SizedBox(
                        height: 48,
                        child: Row(
                          children: [
                            Icon(Icons.sort),
                            SizedBox(width: 8),
                            Text('Sort'),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (current != null &&
                    filter == LibraryFilter.all &&
                    query.trim().isEmpty) ...[
                  const SizedBox(height: 16),
                  Card(
                    margin: EdgeInsets.zero,
                    child: ListTile(
                      minTileHeight: 72,
                      leading: const Icon(
                        Icons.play_circle_outline,
                        color: accent,
                      ),
                      title: const Text('Continue reading'),
                      subtitle: Text(
                        '${current.title} · ${(current.progress * 100).round()}%',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _open(current),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (widget.controller.books.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyLibrary(onImport: _import),
          )
        else if (visible.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('No books match these controls.')),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(horizontal, 12, horizontal, 40),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                // Large accessibility text gets a single wide card on phones.
                maxCrossAxisExtent: scale >= 1.5 ? 600 : 260,
                mainAxisExtent: 390,
                crossAxisSpacing: 22,
                mainAxisSpacing: 24,
              ),
              delegate: SliverChildBuilderDelegate(
                (_, index) => _BookCard(
                  book: visible[index],
                  onOpen: () => _open(visible[index]),
                  onDelete: () => _delete(visible[index]),
                ),
                childCount: visible.length,
              ),
            ),
          ),
      ],
    );
  }
}

String _filterName(LibraryFilter value) => switch (value) {
  LibraryFilter.all => 'All books',
  LibraryFilter.reading => 'Reading',
  LibraryFilter.finished => 'Finished',
};

/// Fixed-width navigation shown when the library has tablet-class width.
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.filter, required this.onFilter});
  final LibraryFilter filter;
  final ValueChanged<LibraryFilter> onFilter;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 220,
    child: Material(
      color: const Color(0xFFF0EDE5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 30, 18, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'READER',
              style: TextStyle(
                letterSpacing: 2,
                fontWeight: FontWeight.bold,
                color: accent,
              ),
            ),
            const SizedBox(height: 34),
            for (final value in LibraryFilter.values)
              ListTile(
                selected: filter == value,
                title: Text(_filterName(value)),
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

/// Import prompt shown before the first book has been added.
class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onImport});
  final VoidCallback onImport;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.menu_book_outlined, size: 58, color: accent),
          const SizedBox(height: 18),
          Text(
            'Your shelf is ready',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontFamily: 'Lora'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Import reflowable, DRM-free EPUB books from Files.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: onImport,
            icon: const Icon(Icons.file_open),
            label: const Text('Import EPUBs'),
          ),
        ],
      ),
    ),
  );
}

/// Catalog tile combining cover art, metadata, progress, and book actions.
class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.onOpen,
    required this.onDelete,
  });
  final CatalogBook book;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _Cover(book: book)),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Lora',
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        book.authorLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Book actions',
                  onSelected: (_) => onDelete(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
          ),
          LinearProgressIndicator(
            value: book.progress,
            minHeight: 4,
            backgroundColor: const Color(0xFFE4DED1),
            color: accent,
          ),
        ],
      ),
    ),
  );
}

/// Displays a cached publication cover or a deterministic typographic cover.
class _Cover extends StatelessWidget {
  const _Cover({required this.book});
  final CatalogBook book;
  @override
  Widget build(BuildContext context) {
    final path = book.coverPath;
    if (path != null && File(path).existsSync()) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _fallback(),
      );
    }
    return _fallback();
  }

  Widget _fallback() {
    final colors = [
      const Color(0xFF315E60),
      const Color(0xFF77534F),
      const Color(0xFFB29353),
      const Color(0xFF555D7D),
    ];
    final color =
        colors[book.hash.codeUnits.fold<int>(0, (a, b) => a + b) %
            colors.length];
    return ColoredBox(
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Center(
          child: Text(
            book.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Lora',
              fontSize: 25,
              height: 1.2,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
