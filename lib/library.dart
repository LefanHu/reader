import 'package:flutter/material.dart';

import 'books.dart';
import 'theme.dart';
import 'reader.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.controller});
  final ReaderController controller;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  LibraryFilter filter = LibraryFilter.all;
  String query = '';
  bool byTitle = false;

  void open(Book book) {
    widget.controller.open(book);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(book: book, controller: widget.controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 700;
        final controller = widget.controller;
        final visible =
            books.where((book) {
              final matches =
                  '${book.title.replaceAll('\n', ' ')} ${book.author}'
                      .toLowerCase()
                      .contains(query.toLowerCase());
              return matches &&
                  switch (filter) {
                    LibraryFilter.all => true,
                    LibraryFilter.reading =>
                      controller.started(book) && controller.progress(book) < 1,
                    LibraryFilter.finished => controller.progress(book) >= 1,
                  };
            }).toList()..sort(
              (a, b) => byTitle
                  ? a.title.compareTo(b.title)
                  : controller
                        .recentIndex(a)
                        .compareTo(controller.recentIndex(b)),
            );
        return Scaffold(
          body: SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide)
                  Container(
                    width: 220,
                    decoration: const BoxDecoration(
                      color: Color(0xFFF0EDE5),
                      border: Border(
                        right: BorderSide(color: Color(0xFFE0DCD2)),
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
                    child: LayoutBuilder(
                      builder: (context, sidebar) => SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: sidebar.maxHeight,
                          ),
                          child: Material(
                            type: MaterialType.transparency,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const _Brand(),
                                const SizedBox(height: 52),
                                const Padding(
                                  padding: EdgeInsets.only(
                                    left: 12,
                                    bottom: 14,
                                  ),
                                  child: Text(
                                    'YOUR SPACE',
                                    style: TextStyle(
                                      fontSize: 10,
                                      letterSpacing: 2,
                                      color: Color(0xFF777C71),
                                    ),
                                  ),
                                ),
                                for (final item in LibraryFilter.values)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: ListTile(
                                      selected: filter == item,
                                      selectedTileColor: const Color(
                                        0xFFE3E4D9,
                                      ),
                                      selectedColor: ink,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      leading: Icon(switch (item) {
                                        LibraryFilter.all =>
                                          Icons.auto_stories_outlined,
                                        LibraryFilter.reading =>
                                          Icons.bookmark_border,
                                        LibraryFilter.finished =>
                                          Icons.check_circle_outline,
                                      }, size: 20),
                                      title: Text(
                                        _filterLabel(item),
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                      onTap: () =>
                                          setState(() => filter = item),
                                    ),
                                  ),
                                const SizedBox(height: 64),
                                const Icon(
                                  Icons.wb_sunny_outlined,
                                  color: accent,
                                  size: 26,
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'A few pages.\nA little perspective.',
                                  style: TextStyle(
                                    fontFamily: 'Lora',
                                    fontSize: 19,
                                    height: 1.5,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'MAKE ROOM FOR READING',
                                  style: TextStyle(
                                    fontSize: 9,
                                    letterSpacing: 1.3,
                                    color: Color(0xFF777C71),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          wide ? 36 : 22,
                          28,
                          wide ? 36 : 22,
                          0,
                        ),
                        sliver: SliverList.list(
                          children: [
                            if (!wide) ...[
                              const _Brand(),
                              const SizedBox(height: 32),
                            ],
                            const Text(
                              'THE READING ROOM',
                              style: TextStyle(
                                color: accent,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 2.4,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'A little time, a world away.',
                              style: TextStyle(
                                fontFamily: 'Lora',
                                fontSize: wide ? 38 : 32,
                                height: 1.15,
                                letterSpacing: -1,
                              ),
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'Find your next chapter. Stay a while.',
                              style: TextStyle(
                                color: Color(0xFF74776E),
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 28),
                            _ContinueCard(
                              book: controller.currentBook ?? books.first,
                              controller: controller,
                              onOpen: open,
                            ),
                            const SizedBox(height: 34),
                            Row(
                              children: [
                                const Expanded(
                                  child: Text(
                                    'Your library',
                                    style: TextStyle(
                                      fontFamily: 'Lora',
                                      fontSize: 26,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${books.length} books',
                                  style: const TextStyle(
                                    color: Color(0xFF74776E),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    onChanged: (value) =>
                                        setState(() => query = value),
                                    decoration: InputDecoration(
                                      hintText: 'Search title or author',
                                      hintStyle: const TextStyle(fontSize: 13),
                                      prefixIcon: const Icon(
                                        Icons.search,
                                        size: 20,
                                      ),
                                      filled: true,
                                      fillColor: const Color(0xFFEEEBE3),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(10),
                                        borderSide: BorderSide.none,
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 12,
                                          ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                PopupMenuButton<bool>(
                                  tooltip: 'Sort books',
                                  initialValue: byTitle,
                                  icon: const Icon(Icons.sort),
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                      value: false,
                                      child: Text('Recently read'),
                                    ),
                                    PopupMenuItem(
                                      value: true,
                                      child: Text('Title A–Z'),
                                    ),
                                  ],
                                  onSelected: (value) =>
                                      setState(() => byTitle = value),
                                ),
                              ],
                            ),
                            if (!wide) ...[
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                children: [
                                  for (final item in LibraryFilter.values)
                                    ChoiceChip(
                                      label: Text(_filterLabel(item)),
                                      selected: filter == item,
                                      onSelected: (_) =>
                                          setState(() => filter = item),
                                    ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 24),
                          ],
                        ),
                      ),
                      if (visible.isEmpty)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.all(40),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.auto_stories_outlined,
                                  size: 36,
                                  color: accent,
                                ),
                                SizedBox(height: 16),
                                Text(
                                  'No books here yet',
                                  style: TextStyle(
                                    fontFamily: 'Lora',
                                    fontSize: 22,
                                  ),
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'Try another search or library filter.',
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        ),
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          wide ? 36 : 22,
                          0,
                          wide ? 36 : 22,
                          32,
                        ),
                        sliver: SliverLayoutBuilder(
                          builder: (context, gridConstraints) {
                            final scale =
                                MediaQuery.textScalerOf(context).scale(14) / 14;
                            final columns = scale > 1.4
                                ? (gridConstraints.crossAxisExtent / 270)
                                      .floor()
                                      .clamp(1, 4)
                                : wide
                                ? (gridConstraints.crossAxisExtent / 180)
                                      .floor()
                                      .clamp(2, 5)
                                : 2;
                            final cardWidth =
                                (gridConstraints.crossAxisExtent -
                                    (columns - 1) * 22) /
                                columns;
                            return SliverGrid.builder(
                              itemCount: visible.length,
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    crossAxisSpacing: 22,
                                    mainAxisSpacing: 24,
                                    mainAxisExtent:
                                        cardWidth * 1.28 + 108 * scale,
                                  ),
                              itemBuilder: (context, index) {
                                final book = visible[index];
                                final progress = controller.progress(book);
                                return Semantics(
                                  button: true,
                                  label:
                                      'Read ${book.title.replaceAll('\n', ' ')} by ${book.author}',
                                  child: InkWell(
                                    onTap: () => open(book),
                                    borderRadius: BorderRadius.circular(8),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        SizedBox(
                                          height: cardWidth * 1.28,
                                          width: double.infinity,
                                          child: BookCover(book: book),
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          book.title.replaceAll('\n', ' '),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          book.author,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFF74776E),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        if (controller.started(book)) ...[
                                          LinearProgressIndicator(
                                            value: progress,
                                            minHeight: 2,
                                            backgroundColor: const Color(
                                              0xFFE4E0D6,
                                            ),
                                            color: book.color,
                                          ),
                                          const SizedBox(height: 5),
                                          Text(
                                            progress >= 1
                                                ? 'Finished'
                                                : '${(progress * 100).round()}% read',
                                            style: const TextStyle(
                                              fontSize: 10,
                                              color: Color(0xFF74776E),
                                            ),
                                          ),
                                        ] else
                                          const Text(
                                            'READY TO DISCOVER',
                                            style: TextStyle(
                                              fontSize: 9,
                                              color: Color(0xFF74776E),
                                              letterSpacing: 1,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

String _filterLabel(LibraryFilter filter) => switch (filter) {
  LibraryFilter.all => 'All books',
  LibraryFilter.reading => 'Reading',
  LibraryFilter.finished => 'Finished',
};

class _Brand extends StatelessWidget {
  const _Brand();
  @override
  Widget build(BuildContext context) => const FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.menu_book_rounded, size: 27, color: accent),
        SizedBox(width: 10),
        Text(
          'reader',
          textScaler: TextScaler.noScaling,
          style: TextStyle(fontFamily: 'Lora', fontSize: 29, letterSpacing: -1),
        ),
        Text(
          '.',
          textScaler: TextScaler.noScaling,
          style: TextStyle(fontFamily: 'Lora', fontSize: 29, color: accent),
        ),
      ],
    ),
  );
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({
    required this.book,
    required this.controller,
    required this.onOpen,
  });
  final Book book;
  final ReaderController controller;
  final ValueChanged<Book> onOpen;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: const Color(0xFF293F38),
      borderRadius: BorderRadius.circular(14),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  controller.started(book)
                      ? 'CONTINUE READING'
                      : 'A GOOD PLACE TO BEGIN',
                  style: const TextStyle(
                    color: Color(0xFFC8D0BD),
                    fontSize: 9,
                    letterSpacing: 1.8,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  book.title.replaceAll('\n', ' '),
                  style: const TextStyle(
                    fontFamily: 'Lora',
                    color: paper,
                    fontSize: 26,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  controller.started(book)
                      ? 'Chapter ${controller.position(book).chapter + 1} · ${(controller.progress(book) * 100).round()}% read'
                      : 'A quiet story of finding your way home.',
                  style: const TextStyle(
                    color: Color(0xFFC8D0BD),
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFF0E8D6),
                    foregroundColor: ink,
                  ),
                  onPressed: () => onOpen(book),
                  icon: const Icon(Icons.arrow_forward, size: 17),
                  label: Text(
                    controller.started(book)
                        ? 'Resume reading'
                        : 'Start reading',
                  ),
                ),
              ],
            ),
          ),
          if (constraints.maxWidth > 420 &&
              MediaQuery.textScalerOf(context).scale(14) < 22) ...[
            const SizedBox(width: 30),
            Transform.rotate(
              angle: 0.08,
              child: SizedBox(
                width: 110,
                height: 155,
                child: BookCover(book: book),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class BookCover extends StatelessWidget {
  const BookCover({super.key, required this.book});
  final Book book;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      decoration: BoxDecoration(
        color: book.color,
        borderRadius: BorderRadius.circular(4),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(2, 5),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(painter: _CoverArt(books.indexOf(book))),
          Container(
            margin: const EdgeInsets.only(left: 5),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
              ),
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) => Padding(
              padding: EdgeInsets.all(constraints.maxWidth * 0.12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.category,
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      color: paper.withValues(alpha: 0.8),
                      fontSize: constraints.maxWidth * 0.043,
                      letterSpacing: 1.6,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    book.title,
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      fontFamily: 'Lora',
                      fontSize: constraints.maxWidth * 0.125,
                      height: 1.12,
                      color: paper,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    book.author.toUpperCase(),
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      fontSize: constraints.maxWidth * 0.045,
                      letterSpacing: 1.4,
                      color: paper,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _CoverArt extends CustomPainter {
  _CoverArt(this.index);
  final int index;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = paper.withValues(alpha: 0.23)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var i = 0; i < 8; i++) {
      final center = Offset(
        size.width * (index.isEven ? 0.8 : 0.3),
        size.height * 0.7,
      );
      if (index % 3 == 0) {
        canvas.drawOval(
          Rect.fromCenter(
            center: center.translate(0, i * 9),
            width: size.width * 1.7,
            height: size.height * 0.26,
          ),
          paint,
        );
      } else if (index % 3 == 1) {
        canvas.drawCircle(center, size.width * 0.13 + i * 10, paint);
      } else {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: center,
              width: 30 + i * 22,
              height: 40 + i * 24,
            ),
            const Radius.circular(60),
          ),
          paint,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CoverArt oldDelegate) => oldDelegate.index != index;
}
