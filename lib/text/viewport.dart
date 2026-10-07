import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import 'direction.dart';
import 'document.dart' as text;

/// Commands address logical reading order rather than visual RTL direction.
class TextReaderNavigation {
  /// Owned by the reader shell and attached only while a viewport is mounted.
  TextReaderNavigation();
  _TextViewportState? _state;

  /// Current logical anchor, retained through typography and viewport changes.
  text.TextPosition? get leadingPosition => _state?._position;

  /// Spatial controls follow the current section's paragraph direction.
  bool get rightToLeft {
    final block = _state?._section?.blocks.first;
    return block != null &&
        paragraphDirection(block.text, block.direction) == TextDirection.rtl;
  }

  /// Bounded engine layout count, exposed for memory regression tests.
  @visibleForTesting
  int get retainedLayoutCount => _state?._cache.length ?? 0;

  /// Advances one page or viewport in logical reading order.
  void next() => _state?._step(1);

  /// Returns one page or viewport in logical reading order.
  void previous() => _state?._step(-1);

  /// Opens the next normalized section.
  void nextSection() => _state?._changeSection(1);

  /// Opens the previous normalized section.
  void previousSection() => _state?._changeSection(-1);

  /// Navigates to a resolved nested contents entry.
  void goTo(text.TextPosition position) => _state?._goTo(position);
}

/// Measured native Flutter text viewport shared by scroll and page modes.
/// Only the active section is loaded; at most two section layouts are retained.
class TextViewport extends StatefulWidget {
  /// The initial position is restored once, then held through every reflow.
  const TextViewport({
    super.key,
    required this.document,
    required this.sourcePath,
    required this.store,
    required this.navigation,
    required this.settings,
    required this.foreground,
    required this.onPosition,
    required this.onTap,
    this.initialPosition,
  });

  /// Immutable manifest used for navigation and source progress.
  final text.TextDocument document;

  /// Private copied source locating normalized sidecars.
  final String sourcePath;

  /// Section loading boundary shared with illustration indexing.
  final text.TextDocumentStore store;

  /// Shell commands attached during this widget's lifecycle.
  final TextReaderNavigation navigation;

  /// Global typography, flow and color choices.
  final ReaderSettings settings;

  /// Current high-contrast ink color.
  final Color foreground;

  /// Optional last durable leading text position.
  final text.TextPosition? initialPosition;

  /// Reports a leading passage and layout-independent progress.
  final void Function(text.TextPosition position, double progress, String title)
  onPosition;

  /// Toggles reading chrome without intercepting drag navigation.
  final VoidCallback onTap;
  @override
  State<TextViewport> createState() => _TextViewportState();
}

class _TextViewportState extends State<TextViewport> {
  final _scroll = ScrollController();
  final _cache = <String, _SectionLayout>{};
  text.TextSection? _section;
  text.TextPosition? _position;
  _SectionLayout? _layout;
  String? _layoutKey;
  Object? _error;
  int _ordinal = 0;
  int _request = 0;
  int _page = 0;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    widget.navigation._state = this;
    _scroll.addListener(_scrolled);
    _goTo(
      widget.initialPosition ??
          text.TextPosition(
            sectionId: widget.document.sections.first.id,
            blockId: '',
          ),
    );
  }

  @override
  void didUpdateWidget(TextViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navigation != widget.navigation) {
      oldWidget.navigation._state = null;
      widget.navigation._state = this;
    }
  }

  Future<void> _goTo(text.TextPosition requested) async {
    final ordinal = widget.document.sections.indexWhere(
      (item) => item.id == requested.sectionId,
    );
    final target = requested.version == text.textDocumentVersion && ordinal >= 0
        ? ordinal
        : 0;
    final generation = ++_request;
    try {
      final section = await widget.store.loadSection(
        widget.sourcePath,
        widget.document.sections[target].id,
      );
      if (!mounted || generation != _request) return;
      setState(() {
        _ordinal = target;
        _section = section;
        _position = section.resolve(requested);
        _layoutKey = null;
        _error = null;
      });
    } on Object catch (error) {
      if (mounted && generation == _request) setState(() => _error = error);
    }
  }

  void _changeSection(int delta) {
    final target = _ordinal + delta;
    if (target < 0 || target >= widget.document.sections.length) return;
    _goTo(
      text.TextPosition(
        sectionId: widget.document.sections[target].id,
        blockId: '',
      ),
    );
  }

  void _step(int delta) {
    final layout = _layout;
    if (layout == null || _restoring) return;
    if (widget.settings.mode == ReadingMode.pages) {
      final target = _page + delta;
      if (target >= 0 && target < layout.pages.length) {
        setState(() => _page = target);
        _report(layout.pages[_page].first.position(_section!.id));
      } else if (delta < 0 && _ordinal > 0) {
        _previousEnd();
      } else if (delta > 0) {
        _advanceOrFinish();
      }
      return;
    }
    if (!_scroll.hasClients) return;
    final target = (_scroll.offset + delta * layout.viewportHeight * .85).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    if (target == _scroll.offset) {
      if (delta < 0) {
        _previousEnd();
      } else {
        _advanceOrFinish();
      }
    } else {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  void _advanceOrFinish() {
    if (_ordinal + 1 < widget.document.sections.length) {
      _changeSection(1);
      return;
    }
    // Advancing beyond the final viewport explicitly acknowledges the ending,
    // allowing completion without treating merely visible text as read.
    final last = _section!.blocks.last;
    _report(
      text.TextPosition(
        sectionId: _section!.id,
        blockId: last.id,
        offset: last.text.length,
      ),
    );
  }

  Future<void> _previousEnd() async {
    if (_ordinal == 0) return;
    final generation = _request;
    final summary = widget.document.sections[_ordinal - 1];
    final section = await widget.store.loadSection(
      widget.sourcePath,
      summary.id,
    );
    if (!mounted || generation != _request) return;
    final last = section.blocks.last;
    await _goTo(
      text.TextPosition(
        sectionId: section.id,
        blockId: last.id,
        offset: last.text.length,
      ),
    );
  }

  void _report(text.TextPosition position) {
    _position = position;
    widget.onPosition(
      position,
      widget.document.progress(_section!, position),
      widget.document.sections[_ordinal].title,
    );
  }

  void _scrolled() {
    if (_restoring ||
        _layout == null ||
        !_scroll.hasClients ||
        widget.settings.mode != ReadingMode.scroll) {
      return;
    }
    final y = _scroll.offset;
    final lines = _layout!.lines;
    if (y >= lines.last.globalTop + lines.last.height) {
      final block = _section!.blocks.last;
      final end = text.TextPosition(
        sectionId: _section!.id,
        blockId: block.id,
        offset: block.text.length,
      );
      if (end != _position) _report(end);
      return;
    }
    var low = 0;
    var high = lines.length - 1;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (lines[mid].globalTop + lines[mid].height <= y) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final line = lines[low];
    final position = line.position(_section!.id);
    if (position != _position) _report(position);
  }

  void _prepare(double width, double height, TextScaler scaler) {
    final section = _section!;
    final key =
        '${section.id}:$width:$height:${widget.settings.fontSize}:${widget.settings.serif}:${widget.foreground.toARGB32()}:${scaler.scale(20)}';
    if (_layoutKey == '$key:${widget.settings.mode.name}') return;
    final layout =
        _cache.remove(key) ??
        _SectionLayout(
          section,
          width,
          height,
          TextStyle(
            fontFamily: widget.settings.serif ? 'Lora' : 'DM Sans',
            fontSize: 20 * widget.settings.fontSize / 100,
            height: 1.6,
            color: widget.foreground,
          ),
          scaler,
        );
    _cache[key] = layout;
    // Retain only current/recent layouts. Every eviction releases engine text
    // paragraphs, not just their Dart references.
    while (_cache.length > 2) {
      _cache.remove(_cache.keys.first)!.dispose();
    }
    _layout = layout;
    _layoutKey = '$key:${widget.settings.mode.name}';
    final position = section.resolve(_position ?? section.start);
    final line = layout.lineFor(position);
    _page = layout.pages.indexWhere((page) => page.contains(line));
    if (_page < 0) _page = 0;
    _restoring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _layout != layout) return;
      if (widget.settings.mode == ReadingMode.scroll && _scroll.hasClients) {
        _scroll.jumpTo(
          line.globalTop.clamp(0.0, _scroll.position.maxScrollExtent),
        );
      }
      _restoring = false;
      // Keep the requested logical anchor during reflow. Reporting the page
      // start here would repeatedly drift backwards as typography changes.
      _report(position);
    });
  }

  @override
  void dispose() {
    if (widget.navigation._state == this) widget.navigation._state = null;
    _scroll.dispose();
    for (final layout in _cache.values) {
      layout.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text('Could not load this section: $_error'));
    }
    if (_section == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(1.0, constraints.maxWidth - 40);
        final height = math.max(1.0, constraints.maxHeight - 24);
        _prepare(width, height, MediaQuery.textScalerOf(context));
        final layout = _layout!;
        final content = widget.settings.mode == ReadingMode.scroll
            ? NotificationListener<OverscrollNotification>(
                onNotification: (notification) {
                  if (_restoring) return false;
                  if (notification.overscroll > 0) {
                    _advanceOrFinish();
                  } else if (notification.overscroll < 0) {
                    _previousEnd();
                  }
                  return false;
                },
                child: SingleChildScrollView(
                  controller: _scroll,
                  physics: const ClampingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final block in layout.blocks)
                        _BlockSlice(
                          block: block,
                          top: 0,
                          height: block.painter.height,
                          start: 0,
                          end: block.block.text.length,
                          bottomPadding: 16,
                        ),
                      SizedBox(height: layout.viewportHeight),
                    ],
                  ),
                ),
              )
            : GestureDetector(
                onHorizontalDragEnd: (details) {
                  final rtl =
                      paragraphDirection(
                        _section!.blocks.first.text,
                        _section!.blocks.first.direction,
                      ) ==
                      TextDirection.rtl;
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity.abs() > 80) {
                    _step((velocity < 0) != rtl ? 1 : -1);
                  }
                },
                child: ClipRect(
                  child: SizedBox(
                    height: height,
                    width: width,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _pageSlices(layout.pages[_page]),
                    ),
                  ),
                ),
              );
        return Focus(
          autofocus: true,
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            final key = event.logicalKey;
            final rtl =
                paragraphDirection(
                  _section!.blocks.first.text,
                  _section!.blocks.first.direction,
                ) ==
                TextDirection.rtl;
            if (key == LogicalKeyboardKey.pageDown ||
                key == LogicalKeyboardKey.space ||
                key ==
                    (rtl
                        ? LogicalKeyboardKey.arrowLeft
                        : LogicalKeyboardKey.arrowRight)) {
              _step(1);
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.pageUp ||
                key ==
                    (rtl
                        ? LogicalKeyboardKey.arrowRight
                        : LogicalKeyboardKey.arrowLeft)) {
              _step(-1);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: content,
            ),
          ),
        );
      },
    );
  }

  List<Widget> _pageSlices(List<_Line> page) {
    final slices = <Widget>[];
    var start = 0;
    while (start < page.length) {
      var end = start + 1;
      while (end < page.length && page[end].block == page[start].block) {
        end++;
      }
      final first = page[start];
      final last = page[end - 1];
      slices.add(
        _BlockSlice(
          block: first.block,
          top: first.top,
          height: last.top + last.height - first.top,
          start: first.start,
          end: last.end,
          bottomPadding: end < page.length ? 16 : 0,
        ),
      );
      start = end;
    }
    return slices;
  }
}

class _MeasuredBlock {
  _MeasuredBlock(this.block, this.painter);
  final text.TextBlock block;
  final TextPainter painter;
}

class _Line {
  _Line(
    this.block,
    this.top,
    this.globalTop,
    this.height,
    this.start,
    this.end,
  );
  final _MeasuredBlock block;
  final double top, globalTop, height;
  final int start, end;
  text.TextPosition position(String section) => text.TextPosition(
    sectionId: section,
    blockId: block.block.id,
    offset: start,
  );
}

class _SectionLayout {
  _SectionLayout(
    text.TextSection section,
    double width,
    this.viewportHeight,
    TextStyle style,
    TextScaler scaler,
  ) {
    var globalTop = 0.0;
    for (final block in section.blocks) {
      final painter = TextPainter(
        text: TextSpan(
          text: block.text,
          style: style.copyWith(
            fontWeight: block.kind == 'heading'
                ? FontWeight.w600
                : FontWeight.normal,
            fontStyle: block.kind == 'quote'
                ? FontStyle.italic
                : FontStyle.normal,
          ),
        ),
        textDirection: paragraphDirection(block.text, block.direction),
        textScaler: scaler,
      )..layout(maxWidth: width);
      final measured = _MeasuredBlock(block, painter);
      blocks.add(measured);
      final metrics = painter.computeLineMetrics();
      var start = 0;
      for (var i = 0; i < metrics.length; i++) {
        final metric = metrics[i];
        final top = metric.baseline - metric.ascent;
        final probe = painter.getPositionForOffset(
          Offset(metric.left + metric.width / 2, top + metric.height / 2),
        );
        final boundary = painter.getLineBoundary(probe);
        var end = i == metrics.length - 1
            ? block.text.length
            : text.graphemeFloor(block.text, boundary.end);
        if (end < block.text.length && block.text[end] == '\n') end++;
        // LineMetrics.height is rounded; use measured top-to-top distances so
        // fractional font sizes cannot accumulate into page overflow.
        final lineHeight = i + 1 < metrics.length
            ? metrics[i + 1].baseline - metrics[i + 1].ascent - top
            : painter.height - top;
        lines.add(
          _Line(measured, top, globalTop + top, lineHeight, start, end),
        );
        start = end;
      }
      globalTop += painter.height + 16;
    }
    var page = <_Line>[];
    var used = 0.0;
    for (final line in lines) {
      final gap = page.isNotEmpty && page.last.block != line.block ? 16.0 : 0.0;
      if (page.isNotEmpty && used + gap + line.height > viewportHeight) {
        pages.add(page);
        page = [];
        used = 0;
      }
      if (page.isNotEmpty && page.last.block != line.block) used += 16;
      page.add(line);
      used += line.height;
    }
    if (page.isNotEmpty) pages.add(page);
  }
  final double viewportHeight;
  final blocks = <_MeasuredBlock>[];
  final lines = <_Line>[];
  final pages = <List<_Line>>[];
  _Line lineFor(text.TextPosition position) =>
      lines
          .where(
            (line) =>
                line.block.block.id == position.blockId &&
                line.start <= position.offset,
          )
          .lastOrNull ??
      lines.first;
  void dispose() {
    for (final block in blocks) {
      block.painter.dispose();
    }
  }
}

class _BlockSlice extends StatelessWidget {
  const _BlockSlice({
    required this.block,
    required this.top,
    required this.height,
    required this.start,
    required this.end,
    required this.bottomPadding,
  });
  final _MeasuredBlock block;
  final double top, height, bottomPadding;
  final int start, end;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: bottomPadding),
    child: Semantics(
      label: block.block.text.substring(start, end),
      textDirection: block.painter.textDirection,
      header: block.block.kind == 'heading',
      child: SizedBox(
        height: height,
        child: ClipRect(
          child: CustomPaint(painter: _TextSlicePainter(block.painter, top)),
        ),
      ),
    ),
  );
}

class _TextSlicePainter extends CustomPainter {
  _TextSlicePainter(this.textPainter, this.top);
  final TextPainter textPainter;
  final double top;
  @override
  void paint(Canvas canvas, Size size) =>
      textPainter.paint(canvas, Offset(0, -top));
  @override
  bool shouldRepaint(_TextSlicePainter oldDelegate) =>
      oldDelegate.textPainter != textPainter || oldDelegate.top != top;
}
