import 'package:flutter/material.dart';

import '../catalog/catalog_book.dart';
import '../catalog_works/work_link.dart';
import '../catalog_works/work_link_coordinator.dart';
import '../identity/cloud_failure_kind.dart';
import '../identity/cloud_identity_exception.dart';
import '../identity/cloud_service_exception.dart';

/// Opens the catalog sheet for [book]; it never blocks or changes reading.
Future<void> showWorkLinkSheet(
  BuildContext context,
  WorkLinkCoordinator works,
  CatalogBook book,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => WorkLinkSheet(works: works, book: book),
);

/// Search the global catalog and link [book] to a work.
///
/// Candidates come from Open Library; a final row links under the file's own
/// title and author for books it does not know. Every action is explicit and
/// may prompt sign-in. Failures stay inline and retryable: a copy that does
/// not match the work's reference reports its match percentage.
class WorkLinkSheet extends StatefulWidget {
  /// Creates the sheet for one local book.
  const WorkLinkSheet({super.key, required this.works, required this.book});

  /// Owner of the book's link state.
  final WorkLinkCoordinator works;

  /// The local copy being linked.
  final CatalogBook book;

  @override
  State<WorkLinkSheet> createState() => _WorkLinkSheetState();
}

class _WorkLinkSheetState extends State<WorkLinkSheet> {
  late final _query = TextEditingController(
    text: [widget.book.title, ...widget.book.authors.take(1)].join(' '),
  );
  List<WorkSummary> _results = const [];
  bool _searched = false;
  bool _degraded = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run(() async {
      await widget.works.refresh(widget.book);
      await _search();
    });
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final search = await widget.works.search(_query.text);
    if (!mounted) return;
    setState(() {
      _results = search.works;
      _degraded = search.degraded;
      _searched = true;
    });
  }

  /// Runs one action at a time and turns its failure into an inline message.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      await action();
    } on CloudIdentityException catch (failure) {
      if (failure.kind != CloudFailureKind.cancelled) error = failure.message;
    } on CloudServiceException catch (failure) {
      error = failure.message;
    } on Object {
      error = 'Something went wrong. Try again.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final link = widget.works.linkFor(widget.book);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .78,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(
                  'Book catalog',
                  style: TextStyle(
                    fontFamily: 'Lora',
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Link your copy to its catalog entry so every copy of the '
                  'same book shares one analysis.',
                ),
              ),
              if (link != null)
                Card(
                  margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: ListTile(
                    leading: const Icon(Icons.link),
                    title: Text(
                      'Linked to ${link.work.title}'
                      '${link.work.author.isEmpty ? '' : ' by ${link.work.author}'}',
                    ),
                    subtitle: Text(
                      '${(link.score * 100).floor()}% of paragraphs match',
                    ),
                    trailing: TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() => widget.works.unlink(widget.book)),
                      child: const Text('Unlink'),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: TextField(
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  enabled: !_busy,
                  decoration: InputDecoration(
                    labelText: 'Search by title and author',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: 'Search',
                      onPressed: _busy ? null : () => _run(_search),
                      icon: const Icon(Icons.search),
                    ),
                  ),
                  onSubmitted: (_) => _run(_search),
                ),
              ),
              SizedBox(
                height: 4,
                child: _busy ? const LinearProgressIndicator() : null,
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Text(
                    _error!,
                    style: TextStyle(color: scheme.error),
                    semanticsLabel: 'Error: $_error',
                  ),
                ),
              if (_degraded)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Text(
                    'The book index is unreachable, so only books already in '
                    'the catalog are shown.',
                  ),
                ),
              Expanded(
                child: ListView(
                  children: [
                    if (_searched && _results.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No books match. Try other words, or use the '
                          'title and author from this file below.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    for (final work in _results) _row(work, link),
                    if (_searched) _fileRow(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(WorkSummary work, WorkLink? link) {
    final linked = link?.work.id == work.id;
    final details = [
      if (work.author.isNotEmpty) work.author,
      if (work.firstPublishYear case final year?) '$year',
      if (work.linked) 'In catalog',
    ].join(' · ');
    return ListTile(
      title: Text(work.title),
      subtitle: details.isEmpty ? null : Text(details),
      trailing: linked
          ? const Icon(Icons.check, semanticLabel: 'Linked')
          : null,
      enabled: !_busy && !linked,
      onTap: () => _run(
        () => widget.works.link(
          widget.book,
          title: work.title,
          author: work.author,
          firstPublishYear: work.firstPublishYear,
        ),
      ),
    );
  }

  /// Links under the file's own metadata, for books the index does not know.
  Widget _fileRow() {
    final book = widget.book;
    final author = book.authors.firstOrNull ?? '';
    return ListTile(
      leading: const Icon(Icons.description_outlined),
      title: const Text("Use this file's title and author"),
      subtitle: Text(author.isEmpty ? book.title : '${book.title} · $author'),
      enabled: !_busy,
      onTap: () => _run(
        () => widget.works.link(book, title: book.title, author: author),
      ),
    );
  }
}
