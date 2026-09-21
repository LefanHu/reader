import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'books.dart';
import 'pagination.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.book, required this.controller});
  final Book book;
  final ReaderController controller;
  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  bool controls = true;
  int chapterNavigation = 0;
  final settingsKey = GlobalKey();
  Object? pageLayout;
  List<TextPage>? cachedPages;

  void chapter(int index) {
    setState(() => chapterNavigation++);
    widget.controller.save(widget.book, index, 0);
  }

  void settings() {
    final panel = _ReaderSettings(controller: widget.controller);
    if (MediaQuery.sizeOf(context).width < 700) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => FractionallySizedBox(heightFactor: 0.8, child: panel),
      );
    } else {
      final box = settingsKey.currentContext!.findRenderObject()! as RenderBox;
      final origin = box.localToGlobal(Offset.zero);
      final screen = MediaQuery.sizeOf(context);
      showDialog<void>(
        context: context,
        builder: (_) => Stack(
          children: [
            Positioned(
              top: origin.dy + box.size.height + 8,
              right: math.max(20, screen.width - origin.dx - box.size.width),
              width: 360,
              height: math.min(
                540,
                screen.height - origin.dy - box.size.height - 28,
              ),
              child: Material(
                elevation: 12,
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: panel,
              ),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final book = widget.book;
      final position = controller.position(book);
      final current = book.chapters[position.chapter];
      final background = switch (controller.theme) {
        ReadingTheme.paper => const Color(0xFFF9F7F1),
        ReadingTheme.sepia => const Color(0xFFECE0C8),
        ReadingTheme.dark => const Color(0xFF202723),
      };
      final foreground = controller.theme == ReadingTheme.dark
          ? const Color(0xFFE5E6DC)
          : const Color(0xFF30372F);
      final style = TextStyle(
        inherit: false,
        fontFamily: controller.serif ? 'Lora' : 'DM Sans',
        fontSize: controller.fontSize,
        height: 1.65,
        color: foreground,
      );
      final scaler = MediaQuery.textScalerOf(context);
      final theme = Theme.of(context).copyWith(
        scaffoldBackgroundColor: background,
        colorScheme: Theme.of(context).colorScheme.copyWith(
          surface: background,
          onSurface: foreground,
          onSurfaceVariant: foreground,
        ),
        iconTheme: IconThemeData(color: foreground),
      );
      return Theme(
        data: theme,
        child: Scaffold(
          backgroundColor: background,
          body: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      if (controls) ...[
                        IconButton(
                          tooltip: 'Back to library',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.arrow_back),
                        ),
                        Expanded(
                          child: Text(
                            book.title.replaceAll('\n', ' '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, color: foreground),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Choose chapter',
                          onPressed: () => showModalBottomSheet<void>(
                            context: context,
                            useSafeArea: true,
                            builder: (sheetContext) => SafeArea(
                              child: ListView(
                                shrinkWrap: true,
                                children: [
                                  const Padding(
                                    padding: EdgeInsets.all(24),
                                    child: Text(
                                      'Chapters',
                                      style: TextStyle(
                                        fontFamily: 'Lora',
                                        fontSize: 24,
                                      ),
                                    ),
                                  ),
                                  for (var i = 0; i < book.chapters.length; i++)
                                    ListTile(
                                      selected: i == position.chapter,
                                      leading: Text('${i + 1}'.padLeft(2, '0')),
                                      title: Text(book.chapters[i].title),
                                      trailing: i == position.chapter
                                          ? const Icon(Icons.bookmark)
                                          : null,
                                      onTap: () {
                                        Navigator.pop(sheetContext);
                                        chapter(i);
                                      },
                                    ),
                                ],
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.list_rounded),
                        ),
                        IconButton(
                          key: settingsKey,
                          tooltip: 'Reading settings',
                          onPressed: settings,
                          icon: const Icon(Icons.text_fields),
                        ),
                      ] else
                        const Spacer(),
                      IconButton(
                        tooltip: controls
                            ? 'Hide reading controls'
                            : 'Show reading controls',
                        onPressed: () => setState(() => controls = !controls),
                        icon: Icon(
                          controls ? Icons.fullscreen : Icons.fullscreen_exit,
                        ),
                      ),
                    ],
                  ),
                ),
                if (controls)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 10, 24, 16),
                    child: Column(
                      children: [
                        Text(
                          'CHAPTER ${position.chapter + 1} OF ${book.chapters.length}',
                          style: TextStyle(
                            color: foreground.withValues(alpha: 0.6),
                            fontSize: 10,
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          current.title,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'Lora',
                            color: foreground,
                            fontSize: 24,
                            height: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: MediaQuery.sizeOf(context).width < 700
                          ? 24
                          : 48,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 680),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            // Reserve footer space independently of the text layout. Page content
                            // and measurement use exactly the same constraints and text scaler.
                            final footerHeight = controls ? 60.0 : 0.0;
                            final size = Size(
                              constraints.maxWidth,
                              math.max(
                                1,
                                constraints.maxHeight - footerHeight - 12,
                              ),
                            );
                            List<TextPage>? pages;
                            if (controller.mode == ReadingMode.pages) {
                              // Color is intentionally excluded: changing paper does not reflow text.
                              final signature = (
                                current.text,
                                size,
                                controller.fontSize,
                                controller.serif,
                                scaler,
                              );
                              if (pageLayout != signature) {
                                pageLayout = signature;
                                cachedPages = paginate(
                                  current.text,
                                  style,
                                  scaler,
                                  size,
                                );
                              }
                              pages = cachedPages;
                            }
                            return _ChapterBody(
                              key: ValueKey((
                                chapterNavigation,
                                position.chapter,
                                controller.mode,
                                size,
                                controller.fontSize,
                                controller.serif,
                                scaler,
                              )),
                              text: current.text,
                              style: style,
                              scaler: scaler,
                              size: size,
                              pages: pages,
                              initialOffset: position.offset,
                              controls: controls,
                              progress: controller.progress(book),
                              onPosition: (offset) => controller.save(
                                book,
                                position.chapter,
                                offset,
                              ),
                              previousChapter: position.chapter > 0
                                  ? () => chapter(position.chapter - 1)
                                  : null,
                              nextChapter: () {
                                if (position.chapter <
                                    book.chapters.length - 1) {
                                  chapter(position.chapter + 1);
                                } else {
                                  controller.save(
                                    book,
                                    position.chapter,
                                    current.text.length,
                                  );
                                  Navigator.pop(context);
                                }
                              },
                              isLastChapter:
                                  position.chapter == book.chapters.length - 1,
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ChapterBody extends StatefulWidget {
  const _ChapterBody({
    super.key,
    required this.text,
    required this.style,
    required this.scaler,
    required this.size,
    required this.pages,
    required this.initialOffset,
    required this.controls,
    required this.progress,
    required this.onPosition,
    required this.previousChapter,
    required this.nextChapter,
    required this.isLastChapter,
  });
  final String text;
  final TextStyle style;
  final TextScaler scaler;
  final Size size;
  final List<TextPage>? pages;
  final int initialOffset;
  final bool controls, isLastChapter;
  final double progress;
  final ValueChanged<int> onPosition;
  final VoidCallback? previousChapter;
  final VoidCallback nextChapter;
  @override
  State<_ChapterBody> createState() => _ChapterBodyState();
}

class _ChapterBodyState extends State<_ChapterBody> {
  late final TextPainter painter;
  late final ScrollController scroll;
  late final PageController pager;
  late int page;
  bool restoring = true;

  @override
  void initState() {
    super.initState();
    painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      textDirection: TextDirection.ltr,
      textScaler: widget.scaler,
    )..layout(maxWidth: widget.size.width);
    final pages = widget.pages;
    page = pages == null
        ? 0
        : pages.indexWhere((p) => widget.initialOffset < p.end);
    if (page < 0) page = (pages?.length ?? 1) - 1;
    pager = PageController(initialPage: page);
    scroll = ScrollController()..addListener(saveScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (scroll.hasClients) {
        final target = painter
            .getOffsetForCaret(
              TextPosition(offset: widget.initialOffset),
              Rect.zero,
            )
            .dy;
        scroll.jumpTo(target.clamp(0, scroll.position.maxScrollExtent));
      }
      restoring = false;
    });
  }

  void saveScroll() {
    if (restoring || !scroll.hasClients) return;
    final offset =
        scroll.offset >= scroll.position.maxScrollExtent - 1 &&
            scroll.position.maxScrollExtent > 0
        ? widget.text.length
        : painter.getPositionForOffset(Offset(0, scroll.offset + 1)).offset;
    widget.onPosition(offset);
  }

  void movePage(int delta) {
    final target = page + delta;
    if (target < 0) {
      widget.previousChapter?.call();
      return;
    }
    if (target >= widget.pages!.length) {
      widget.nextChapter();
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      pager.jumpToPage(target);
    } else {
      pager.animateToPage(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    pager.dispose();
    painter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = widget.pages;
    final canGoBack = pages == null
        ? widget.previousChapter != null
        : page > 0 || widget.previousChapter != null;
    final atEnd = pages == null || page == pages.length - 1;
    final nextLabel = atEnd
        ? (widget.isLastChapter ? 'Finish book' : 'Next chapter')
        : 'Next page';
    return Column(
      children: [
        SizedBox(
          height: widget.size.height,
          child: pages == null
              ? SingleChildScrollView(
                  key: const ValueKey('chapter-scroll'),
                  controller: scroll,
                  child: Text(
                    widget.text,
                    style: widget.style,
                    textScaler: widget.scaler,
                  ),
                )
              : PageView.builder(
                  key: const ValueKey('chapter-pages'),
                  controller: pager,
                  itemCount: pages.length,
                  onPageChanged: (index) {
                    setState(() => page = index);
                    if (!restoring) widget.onPosition(pages[index].start);
                  },
                  itemBuilder: (context, index) => Semantics(
                    label: 'Page ${index + 1} of ${pages.length}',
                    child: Text(
                      widget.text.substring(
                        pages[index].start,
                        pages[index].end,
                      ),
                      style: widget.style,
                      textScaler: widget.scaler,
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 12),
        if (widget.controls)
          SizedBox(
            height: 60,
            child: Row(
              children: [
                IconButton(
                  tooltip: pages == null || page == 0
                      ? 'Previous chapter'
                      : 'Previous page',
                  onPressed: canGoBack
                      ? () => pages == null
                            ? widget.previousChapter?.call()
                            : movePage(-1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      pages == null
                          ? '${(widget.progress * 100).round()}% of book'
                          : '${page + 1} / ${pages.length} · ${(widget.progress * 100).round()}%',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: widget.style.color?.withValues(alpha: 0.65),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: nextLabel,
                  onPressed: () =>
                      pages == null ? widget.nextChapter() : movePage(1),
                  icon: Icon(
                    atEnd && widget.isLastChapter
                        ? Icons.check
                        : Icons.chevron_right,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ReaderSettings extends StatelessWidget {
  const _ReaderSettings({required this.controller});
  final ReaderController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Make yourself at home',
                  style: TextStyle(fontFamily: 'Lora', fontSize: 22),
                ),
              ),
              IconButton(
                tooltip: 'Close settings',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text(
            'READING MODE',
            style: TextStyle(fontSize: 10, letterSpacing: 1.5),
          ),
          const SizedBox(height: 10),
          SegmentedButton<ReadingMode>(
            segments: const [
              ButtonSegment(
                value: ReadingMode.pages,
                label: Text('Pages'),
                icon: Icon(Icons.menu_book_outlined),
              ),
              ButtonSegment(
                value: ReadingMode.scroll,
                label: Text('Scroll'),
                icon: Icon(Icons.swap_vert),
              ),
            ],
            selected: {controller.mode},
            onSelectionChanged: (value) =>
                controller.configure(mode: value.single),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              const Expanded(child: Text('Text size')),
              Text('${controller.fontSize.round()}'),
            ],
          ),
          Slider(
            value: controller.fontSize,
            min: 16,
            max: 30,
            divisions: 7,
            label: '${controller.fontSize.round()}',
            semanticFormatterCallback: (value) => 'Text size ${value.round()}',
            onChanged: (value) => controller.configure(fontSize: value),
          ),
          const Text(
            'TYPEFACE',
            style: TextStyle(fontSize: 10, letterSpacing: 1.5),
          ),
          const SizedBox(height: 10),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Serif')),
              ButtonSegment(value: false, label: Text('Sans serif')),
            ],
            selected: {controller.serif},
            onSelectionChanged: (value) =>
                controller.configure(serif: value.single),
          ),
          const SizedBox(height: 24),
          const Text(
            'PAGE COLOR',
            style: TextStyle(fontSize: 10, letterSpacing: 1.5),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final theme in ReadingTheme.values)
                ChoiceChip(
                  label: Text(switch (theme) {
                    ReadingTheme.paper => 'Paper',
                    ReadingTheme.sepia => 'Sepia',
                    ReadingTheme.dark => 'Dark',
                  }),
                  selected: controller.theme == theme,
                  onSelected: (_) => controller.configure(theme: theme),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    ),
  );
}
