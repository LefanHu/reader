import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/reader_controller.dart';
import '../settings/settings_navigation.dart';
import '../catalog/catalog_book.dart';
import '../importing/import_result.dart';
import '../preferences/library_filter.dart';
import '../preferences/library_sort.dart';
import '../narration/mini_player.dart';
import '../reader/reader_screen.dart';
import 'appearance_menu.dart';
import 'resume_book_card.dart';
import 'library_sidebar.dart';
import 'empty_library.dart';
import 'book_card.dart';
import 'book_row.dart';

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
  late LibraryFilter _savedFilter;
  late LibrarySort _savedSort;

  @override
  void initState() {
    super.initState();
    filter = _savedFilter =
        widget.controller.preferences.settings.libraryFilter;
    sort = _savedSort = widget.controller.preferences.settings.librarySort;
    widget.controller.addListener(_preferencesChanged);
  }

  // Temporary catalog selections remain independent until saved defaults change.
  void _preferencesChanged() {
    final settings = widget.controller.preferences.settings;
    if (settings.libraryFilter == _savedFilter &&
        settings.librarySort == _savedSort) {
      return;
    }
    setState(() {
      if (settings.libraryFilter != _savedFilter) {
        filter = settings.libraryFilter;
      }
      if (settings.librarySort != _savedSort) sort = settings.librarySort;
      _savedFilter = settings.libraryFilter;
      _savedSort = settings.librarySort;
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_preferencesChanged);
    super.dispose();
  }

  Future<void> _import() async {
    List<ImportResult> results;
    try {
      results = await widget.controller.catalog.pickAndImport();
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
    final books = widget.controller.catalog.books.where((book) {
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
          bottomNavigationBar: widget.controller.narration?.book == null
              ? null
              : NarrationMiniPlayer(controller: widget.controller),
          body: SafeArea(
            child: Stack(
              children: [
                Row(
                  children: [
                    if (wide)
                      LibrarySidebar(
                        filter: filter,
                        onFilter: (value) => setState(() => filter = value),
                      ),
                    Expanded(child: _content(wide, constraints.maxWidth)),
                  ],
                ),
                if (widget.controller.catalog.importing)
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
                                'Importing ${widget.controller.catalog.importDone + 1} of ${widget.controller.catalog.importTotal}',
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(),
                                const SizedBox(height: 16),
                                Text(
                                  'Importing ${widget.controller.catalog.importDone + 1} of ${widget.controller.catalog.importTotal}',
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
    final current = widget.controller.catalog.currentBook;
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
            (value) => DropdownMenuItem(
              value: value,
              child: Text(libraryFilterLabel(value)),
            ),
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
                    LibraryAppearanceMenu(controller: widget.controller),
                    IconButton(
                      tooltip: 'Settings',
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: () => SettingsNavigation.open(
                        Navigator.of(context),
                        widget.controller,
                      ),
                    ),
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
                    child: ResumeBookCard(
                      book: current,
                      onOpen: () => _open(current),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (widget.controller.catalog.books.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyLibrary(onImport: _import),
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
                    itemBuilder: (_, index) => BookRow(
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
                          (_, index) => BookCard(
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
