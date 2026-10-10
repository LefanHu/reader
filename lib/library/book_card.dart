import 'package:flutter/material.dart';

import '../catalog/catalog_book.dart';
import 'book_actions.dart';
import 'book_cover.dart';
import 'book_details.dart';
import 'book_progress.dart';

/// Stationary macOS cover tile; metadata reveals on hover or descendant focus.
/// Menus retain the reveal after the pointer leaves. Hidden actions cannot focus.
class BookCard extends StatefulWidget {
  /// Creates this library component with its book or action inputs.
  const BookCard({
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
  State<BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<BookCard> {
  bool _hovered = false, _focused = false, _menuOpen = false;
  @override
  Widget build(BuildContext context) {
    final visible = _hovered || _focused || _menuOpen;
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      key: ValueKey('library-book-${widget.book.hash}'),
      label: bookSemanticsLabel(widget.book),
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
                        ExcludeSemantics(child: BookCover(book: widget.book)),
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
                                              child: BookDetails(
                                                book: widget.book,
                                              ),
                                            ),
                                            BookActions(
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
                BookProgress(book: widget.book),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
