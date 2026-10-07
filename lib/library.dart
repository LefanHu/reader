import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'models.dart';
import 'reader.dart';
import 'text/word_count.dart';

/// Adaptive catalog for importing, finding, opening, and deleting books.
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
                    Expanded(child: _content(wide, constraints.maxWidth)),
                  ],
                ),
                if (widget.controller.importing)
                  // Block overlapping picker/import actions to bound staged source memory.
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

  Widget _content(bool wide, double windowWidth) {
    final visible = _visible();
    final current = widget.controller.currentBook;
    final scaler = MediaQuery.textScalerOf(context);
    // Presentation follows the platform, not iPad/window width. Width still
    // selects the existing sidebar and header arrangements independently.
    final list = Theme.of(context).platform == TargetPlatform.iOS;
    final horizontal = wide ? 32.0 : 20.0;
    final contentWidth = windowWidth - (wide ? 200 : 0) - horizontal * 2;
    final search = TextField(
      onChanged: (value) => setState(() => query = value),
      decoration: const InputDecoration(
        prefixIcon: Icon(Icons.search),
        hintText: 'Search title or author',
      ),
    );
    final sortControl = PopupMenuButton<LibrarySort>(
      tooltip: 'Sort books',
      initialValue: sort,
      onSelected: (value) => setState(() => sort = value),
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: LibrarySort.recent,
          child: Text('Recent activity'),
        ),
        PopupMenuItem(value: LibrarySort.title, child: Text('Title A–Z')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sort, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  sort == LibrarySort.recent ? 'Recent activity' : 'Title A–Z',
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.expand_more, size: 18),
            ],
          ),
        ),
      ),
    );
    final filterControl = DropdownButtonFormField<LibraryFilter>(
      initialValue: filter,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Filter'),
      items: LibraryFilter.values
          .map(
            (value) =>
                DropdownMenuItem(value: value, child: Text(_filterName(value))),
          )
          .toList(),
      onChanged: (value) => setState(() => filter = value!),
    );
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(horizontal, 24, horizontal, 24),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Your library',
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
                              fontFamily: 'Lora',
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                    if (wide && scaler.scale(1) < 1.5)
                      FilledButton.icon(
                        onPressed: _import,
                        icon: const Icon(Icons.add),
                        label: const Text('Import books'),
                      )
                    else
                      IconButton.filled(
                        tooltip: 'Import books',
                        color: Theme.of(context).colorScheme.onPrimary,
                        onPressed: _import,
                        icon: const Icon(Icons.add),
                      ),
                    const SizedBox(width: 8),
                    _AppearanceMenu(controller: widget.controller),
                  ],
                ),
                const SizedBox(height: 20),
                // Wrapping is intentional: narrow windows and large type must
                // keep search and filter usable without squeezing their labels.
                if (wide && scaler.scale(1) < 1.5)
                  Row(
                    children: [
                      Expanded(child: search),
                      const SizedBox(width: 16),
                      sortControl,
                    ],
                  )
                else ...[
                  search,
                  const SizedBox(height: 12),
                  if (!wide && scaler.scale(1) < 1.5 && contentWidth >= 340)
                    Row(
                      children: [
                        Expanded(child: filterControl),
                        const SizedBox(width: 8),
                        sortControl,
                      ],
                    )
                  else
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        if (!wide)
                          SizedBox(
                            width: math.min(220, contentWidth),
                            child: filterControl,
                          ),
                        sortControl,
                      ],
                    ),
                ],
                if (current != null &&
                    filter == LibraryFilter.all &&
                    query.trim().isEmpty) ...[
                  const SizedBox(height: 20),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: _ResumeCard(
                      book: current,
                      onOpen: () => _open(current),
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
            padding: EdgeInsets.fromLTRB(horizontal, 0, horizontal, 40),
            sliver: list
                ? SliverList.separated(
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, index) => _BookRow(
                      book: visible[index],
                      onOpen: () => _open(visible[index]),
                      onDelete: () => _delete(visible[index]),
                    ),
                  )
                : SliverLayoutBuilder(
                    builder: (context, constraints) {
                      final gap = wide ? 24.0 : 16.0;
                      final columns = math.max(
                        1,
                        ((constraints.crossAxisExtent + gap) / (200 + gap))
                            .ceil(),
                      );
                      final width =
                          (constraints.crossAxisExtent - gap * (columns - 1)) /
                          columns;
                      return SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisExtent: width * 1.5 + 7,
                          crossAxisSpacing: gap,
                          mainAxisSpacing: gap,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (_, index) => _BookCard(
                            book: visible[index],
                            onOpen: () => _open(visible[index]),
                            onDelete: () => _delete(visible[index]),
                          ),
                          childCount: visible.length,
                        ),
                      );
                    },
                  ),
          ),
      ],
    );
  }
}

/// Library entry point to the persisted app-wide palette and dependency notices.
/// Menu radios retain their selected semantics and close after a choice.
class _AppearanceMenu extends StatefulWidget {
  const _AppearanceMenu({required this.controller});
  final ReaderController controller;
  @override
  State<_AppearanceMenu> createState() => _AppearanceMenuState();
}

class _AppearanceMenuState extends State<_AppearanceMenu> {
  final menu = MenuController();
  @override
  Widget build(BuildContext context) => MenuAnchor(
    controller: menu,
    builder: (context, controller, _) => IconButton(
      tooltip: 'Appearance',
      icon: const Icon(Icons.palette_outlined),
      onPressed: () =>
          controller.isOpen ? controller.close() : controller.open(),
    ),
    menuChildren: [
      for (final preset in ReadingTheme.values)
        RadioMenuButton<ReadingTheme>(
          value: preset,
          groupValue: widget.controller.settings.theme,
          onChanged: (value) {
            if (value != null) widget.controller.configure(theme: value);
          },
          child: Text(switch (preset) {
            ReadingTheme.paper => 'Paper',
            ReadingTheme.sepia => 'Sepia',
            ReadingTheme.dark => 'Dark',
          }),
        ),
      const Divider(),
      MenuItemButton(
        onPressed: () {
          menu.close();
          showLicensePage(
            context: context,
            applicationName: 'Reader',
            applicationLegalese: 'Text layout uses Flutter with Unicode-aware passage positions.',
          );
        },
        leadingIcon: const Icon(Icons.info_outline),
        child: const Text('Open source licenses'),
      ),
    ],
  );
}

/// A restrained resume action; its width does not stretch across desktop shelves.
class _ResumeCard extends StatelessWidget {
  const _ResumeCard({required this.book, required this.onOpen});
  final CatalogBook book;
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
                  child: _Cover(book: book, thumbnail: true),
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
          Icon(
            Icons.menu_book_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 18),
          Text(
            'Your shelf is ready',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontFamily: 'Lora'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Import EPUB or TXT books from Files.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: onImport,
            icon: const Icon(Icons.file_open),
            label: const Text('Import books'),
          ),
        ],
      ),
    ),
  );
}

/// Shared metadata remains available to assistive technology without hover.
String _bookLabel(CatalogBook book) => [
  book.title,
  book.authorLine,
  if (book.wordCount != null) 'Approximately ${book.wordCount} words',
  '${(book.progress * 100).round()}% read',
].join(', ');

/// Metadata uses content-driven heights in lists and a scrollable cover overlay.
class _BookDetails extends StatelessWidget {
  const _BookDetails({required this.book});
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

/// Independent action target; opening its menu pins a desktop metadata overlay.
class _BookActions extends StatelessWidget {
  const _BookActions({required this.onDelete, this.onMenuChanged});
  final VoidCallback onDelete;
  final ValueChanged<bool>? onMenuChanged;
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Book actions',
    onOpened: () => onMenuChanged?.call(true),
    onCanceled: () => onMenuChanged?.call(false),
    onSelected: (_) {
      onMenuChanged?.call(false);
      onDelete();
    },
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'delete', child: Text('Delete')),
    ],
  );
}

/// Stationary macOS cover tile; metadata reveals on hover or descendant focus.
/// Menus retain the reveal after the pointer leaves. Hidden actions cannot focus.
class _BookCard extends StatefulWidget {
  const _BookCard({
    required this.book,
    required this.onOpen,
    required this.onDelete,
  });
  final CatalogBook book;
  final VoidCallback onOpen, onDelete;
  @override
  State<_BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<_BookCard> {
  bool _hovered = false, _focused = false, _menuOpen = false;
  @override
  Widget build(BuildContext context) {
    final visible = _hovered || _focused || _menuOpen;
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      key: ValueKey('library-book-${widget.book.hash}'),
      label: _bookLabel(widget.book),
      button: true,
      child: Focus(
        skipTraversal: true,
        onFocusChange: (value) => setState(() => _focused = value),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onHover: (value) => setState(() => _hovered = value),
            onTap: widget.onOpen,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 2 / 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ExcludeSemantics(child: _Cover(book: widget.book)),
                        IgnorePointer(
                          ignoring: !visible,
                          child: ExcludeFocus(
                            excluding: !visible,
                            child: ExcludeSemantics(
                              excluding: !visible,
                              child: AnimatedOpacity(
                                opacity: visible ? 1 : 0,
                                duration:
                                    MediaQuery.disableAnimationsOf(context)
                                    ? Duration.zero
                                    : const Duration(milliseconds: 150),
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: Material(
                                    color: colors.surfaceContainer,
                                    child: SingleChildScrollView(
                                      child: Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          12,
                                          8,
                                          4,
                                          12,
                                        ),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: _BookDetails(
                                                book: widget.book,
                                              ),
                                            ),
                                            _BookActions(
                                              onDelete: widget.onDelete,
                                              onMenuChanged: (value) =>
                                                  setState(
                                                    () => _menuOpen = value,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                _BookProgress(book: widget.book),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// iOS uses a lazy, content-sized row even on wide iPads and at large text sizes.
class _BookRow extends StatelessWidget {
  const _BookRow({
    required this.book,
    required this.onOpen,
    required this.onDelete,
  });
  final CatalogBook book;
  final VoidCallback onOpen, onDelete;
  @override
  Widget build(BuildContext context) => Semantics(
    key: ValueKey('library-book-${book.hash}'),
    label: _bookLabel(book),
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
                    child: _Cover(book: book, thumbnail: true),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _BookDetails(book: book),
                    const SizedBox(height: 12),
                    _BookProgress(book: book),
                  ],
                ),
              ),
              _BookActions(onDelete: onDelete),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Progress stays visible without desktop metadata and shares the app palette.
class _BookProgress extends StatelessWidget {
  const _BookProgress({required this.book});
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

/// Displays a cached publication cover or a deterministic typographic cover.
class _Cover extends StatelessWidget {
  const _Cover({required this.book, this.thumbnail = false});
  final CatalogBook book;
  // Resume thumbnails use an icon instead of unreadably compressed titles.
  final bool thumbnail;
  @override
  Widget build(BuildContext context) {
    final path = book.coverPath;
    if (path != null && File(path).existsSync()) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: Image.file(
          File(path),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => _fallback(),
        ),
      );
    }
    return _fallback();
  }

  Widget _fallback() {
    final colors = [
      const Color(0xFF315E60),
      const Color(0xFF77534F),
      const Color(0xFF725F35),
      const Color(0xFF555D7D),
    ];
    final color =
        colors[book.hash.codeUnits.fold<int>(0, (a, b) => a + b) %
            colors.length];
    return ColoredBox(
      color: color,
      child: thumbnail
          ? const Center(
              child: Icon(
                Icons.menu_book_outlined,
                size: 20,
                color: Colors.white,
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: Text(
                  book.title,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Lora',
                    fontSize: 18,
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
