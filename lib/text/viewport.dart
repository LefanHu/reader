import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'layout/section_layout_cache.dart';
import 'reader_key_navigation.dart';
import 'reader_text_style.dart';

import '../preferences/reader_settings.dart';
import '../preferences/reading_mode.dart';
import 'direction.dart';
import 'document.dart' as text;
import 'page_curl.dart';
import 'document_store.dart' as text;
import 'text_section.dart' as text;
import 'text_position.dart' as text;
import 'reader_navigation.dart';
import 'page_target.dart';
import 'page_turn_controller.dart';
import '../generation_fence.dart';
import 'layout/section_layout.dart';
import 'narration_range.dart';
import 'narration_follow_target.dart';
import 'text_page_slices.dart';
import 'reader_gesture_surface.dart';
import 'reader_selection_content.dart';
import 'reader_selection_region.dart';

/// Measured native Flutter text viewport shared by scroll and page modes.
/// At most two section layouts are retained, including an adjacent curl preview.
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
    this.background = const Color(0xFFFFFBF0),
    required this.onPosition,
    required this.onTap,
    this.initialPosition,
    this.initialPositionIsRestoration = false,
    this.onManualNavigation,
    this.onRestored,
    this.onReadFromHere,
    this.activeNarrationRange,
    this.figureBlocks = const {},
    this.figureBuilder,
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

  /// Opaque theme paper used by page textures and the curl's reverse side.
  final Color background;

  /// Optional last durable leading text position.
  final text.TextPosition? initialPosition;

  /// Silently restores a presentation-only initial anchor, even if playback
  /// pauses while loading. Ordinary initial positions still report progress.
  final bool initialPositionIsRestoration;

  /// Reports a leading passage and layout-independent progress. Curl previews
  /// never report: only completed turns may persist progress.
  final void Function(text.TextPosition position, double progress, String title)
  onPosition;

  /// Silent restore updates chapter labels without writing reading progress.
  final void Function(String title)? onRestored;

  /// Pauses narration before a user page, chapter, gesture, or scroll can commit.
  final VoidCallback? onManualNavigation;

  /// Starts narration from the selected paragraph without committing progress.
  /// Source identities come from selection leaves, never a text search.
  final ValueChanged<text.TextPosition>? onReadFromHere;

  /// Complete normalized spoken bounds. Decoration never changes selection,
  /// reflows text, or commits reading progress.
  final NarrationRange? activeNarrationRange;

  /// Section ID → block IDs followed by an inline figure slot; part of layout
  /// identity, so changing it reflows and restores the logical position.
  final Map<String, Set<String>> figureBlocks;

  /// Builds the content of one figure slot. The slot's size is fixed by the
  /// layout; the builder must fill it and own its own semantics.
  final Widget Function(String sectionId, String blockId)? figureBuilder;

  /// Toggles reading chrome without intercepting drag navigation.
  final VoidCallback onTap;
  @override
  State<TextViewport> createState() => _TextViewportState();
}

class _TextViewportState extends State<TextViewport>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final PageTurnController _turns;
  double _width = 1, _height = 1;
  TextScaler _scaler = TextScaler.noScaling;
  ScrollController _scroll = ScrollController(keepScrollOffset: false);
  int _restoreGeneration = 0;
  final _layouts = SectionLayoutCache();
  text.TextSection? _section;
  text.TextPosition? _position;
  SectionLayout? _layout;
  Object? _layoutKey;
  Object? _error;
  int _ordinal = 0;
  int _request = 0;
  int _page = 0;
  bool _restoring = false;
  bool _restorationOnly = false;
  Completer<void>? _restored;
  final _selection = GlobalKey<ReaderSelectionRegionState>();
  bool _selectionActive = false;
  String? _selectedBlock;

  void _readSelectedParagraph() {
    final section = _section;
    final block = _selectedBlock;
    if (section == null || block == null || !_selectionActive) return;
    widget.onReadFromHere?.call(
      text.TextPosition(sectionId: section.id, blockId: block),
    );
  }

  void _clearSelection() {
    _selectionActive = false;
    _selectedBlock = null;
    _selection.currentState?.clearSelection();
  }

  void _selectionChanged(bool active) {
    if (!mounted || _selectionActive == active) return;
    _selectionActive = active;
    // Selection always belongs to the committed page, never a curl preview.
    if (active && _turns.busy) _turns.cancel();
    setState(() {});
  }

  void _manualNavigation() {
    _restorationOnly = false;
    widget.onManualNavigation?.call();
  }

  bool get _rightToLeft {
    final block = _section?.blocks.first;
    return block != null &&
        paragraphDirection(block.text, block.direction) == TextDirection.rtl;
  }

  void _attachNavigation() {
    widget.navigation.attach(
      this,
      leadingPosition: () => _position,
      rightToLeft: () => _rightToLeft,
      retainedLayoutCount: () => _layouts.length,
      retainedTextureCount: () => _turns.turn?.current == null ? 0 : 2,
      next: () => _step(1),
      previous: () => _step(-1),
      nextSection: () => _changeSection(1),
      previousSection: () => _changeSection(-1),
      goTo: (position) {
        _manualNavigation();
        _goTo(position);
      },
      restore: (position) => _goTo(position, restoration: true),
      follow: _follow,
    );
  }

  @override
  void initState() {
    super.initState();
    _attachNavigation();
    WidgetsBinding.instance.addObserver(this);
    _turns = PageTurnController(
      vsync: this,
      ready: () => _layout != null && !_restoring,
      committed: () => PageTarget(_ordinal, _section!, _layout!, _page),
      resolve: _resolvePage,
      texture: _texture,
      commit: _commitPage,
      pastEnd: _advanceOrFinish,
      rightToLeft: () => _rightToLeft,
      width: () => _width,
      changed: () => setState(() {}),
    );
    _scroll.addListener(_scrolled);
    _goTo(
      widget.initialPosition ??
          text.TextPosition(
            sectionId: widget.document.sections.first.id,
            blockId: '',
          ),
      restoration: widget.initialPositionIsRestoration,
    );
  }

  @override
  void didUpdateWidget(TextViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings ||
        oldWidget.foreground != widget.foreground ||
        oldWidget.background != widget.background) {
      _clearSelection();
      _turns.cancel();
    }
    if (oldWidget.navigation != widget.navigation) {
      oldWidget.navigation.detach(this);
      _attachNavigation();
    }
  }

  Future<void> _follow(
    text.TextPosition target,
    bool Function() isCurrent,
  ) async {
    if (!mounted ||
        _selectionActive ||
        !isCurrent() ||
        !widget.document.sections.any((item) => item.id == target.sectionId)) {
      return;
    }
    final layout = _layout;
    if (layout != null &&
        narrationTargetVisible(
          target: target,
          sectionId: _section!.id,
          layout: layout,
          page: widget.settings.mode == ReadingMode.scroll ? null : _page,
          scrollOffset: _scroll.hasClients ? _scroll.offset : 0,
          viewportExtent: _height,
        )) {
      return;
    }
    await _goTo(target, restoration: true, isCurrent: isCurrent);
  }

  Future<void> _goTo(
    text.TextPosition requested, {
    bool restoration = false,
    bool Function()? isCurrent,
  }) async {
    if (isCurrent?.call() == false) return;
    _clearSelection();
    if (_restored?.isCompleted == false) _restored!.complete();
    _restored = restoration ? Completer<void>() : null;
    final restored = _restored;
    _restorationOnly = restoration;
    final hadTurn = _turns.busy;
    _turns.cancel();
    if (hadTurn && mounted) setState(() {});
    final ordinal = widget.document.ordinalOf(requested.sectionId);
    final target = ordinal >= 0 ? ordinal : 0;
    final generation = ++_request;
    ++_restoreGeneration;
    try {
      final section = await widget.store.loadSection(
        widget.sourcePath,
        widget.document.sections[target].id,
      );
      if (!mounted ||
          generation != _request ||
          isCurrent?.call() == false ||
          (isCurrent != null && section.resolve(requested) != requested)) {
        if (restored != null && !restored.isCompleted) restored.complete();
        return;
      }
      setState(() {
        _ordinal = target;
        _section = section;
        _position = section.resolve(requested);
        _layoutKey = null;
        _error = null;
      });
    } on Object catch (error) {
      if (mounted && generation == _request && isCurrent?.call() != false) {
        setState(() => _error = error);
      }
      if (restored != null && !restored.isCompleted) restored.complete();
    } finally {
      if (identical(_restored, restored) && restored?.isCompleted == true) {
        _restored = null;
        _restorationOnly = false;
      }
    }
    if (restored != null) await restored.future;
  }

  void _changeSection(int delta) {
    _manualNavigation();
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
    _clearSelection();
    _manualNavigation();
    final layout = _layout;
    if (layout == null || _restoring) return;
    if (widget.settings.mode != ReadingMode.scroll) {
      _turns.step(
        delta,
        animated: widget.settings.mode == ReadingMode.pageFlip,
      );
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _clearSelection();
      _turns.cancel();
      if (mounted) setState(() {});
    }
  }

  // Adjacent pages use the same measured layout as the current viewport. The
  // turn ticket prevents chapter jumps/reflows accepting stale loads.
  Future<PageTarget?> _resolvePage(int delta, FenceTicket ticket) async {
    final index = _page + delta;
    if (index >= 0 && index < _layout!.pages.length) {
      return PageTarget(_ordinal, _section!, _layout!, index);
    }
    final ordinal = _ordinal + delta;
    if (ordinal < 0 || ordinal >= widget.document.sections.length) return null;
    final section = await widget.store.loadSection(
      widget.sourcePath,
      widget.document.sections[ordinal].id,
    );
    if (!mounted || !ticket.isCurrent) return null;
    final layout = _obtainLayout(section, _width, _height, _scaler);
    return PageTarget(
      ordinal,
      section,
      layout,
      delta > 0 ? 0 : layout.pages.length - 1,
    );
  }

  void _commitPage(PageTarget target) {
    setState(() {
      _ordinal = target.ordinal;
      _section = target.section;
      _layout = target.layout;
      _page = target.page;
      _layoutKey = (
        _layouts.keyFor(
          section: target.section,
          width: _width,
          height: _height,
          style: _style,
          scaler: _scaler,
          figureBlockIds: _figureIds(target.section.id),
        ),
        widget.settings.mode,
      );
    });
    _report(target.layout.pages[target.page].first.position(target.section.id));
  }

  ui.Image _texture(PageTarget target) => textPageTexture(
    layout: target.layout,
    page: target.page,
    width: _width,
    height: _height,
    background: widget.background,
    figureColor: Color.alphaBlend(
      widget.foreground.withValues(alpha: .08),
      widget.background,
    ),
  );

  void _advanceOrFinish() {
    if (_ordinal + 1 < widget.document.sections.length) {
      _changeSection(1);
      return;
    }
    // Advancing beyond the final viewport explicitly acknowledges the ending,
    // allowing completion without treating merely visible text as read.
    _report(_section!.end);
  }

  Future<void> _previousEnd() async {
    if (_ordinal == 0) return;
    final generation = _request;
    final summary = widget.document.sections[_ordinal - 1];
    final text.TextSection section;
    try {
      section = await widget.store.loadSection(widget.sourcePath, summary.id);
    } on Object catch (error) {
      if (mounted && generation == _request) setState(() => _error = error);
      return;
    }
    if (!mounted || generation != _request) return;
    await _goTo(section.end);
  }

  void _report(text.TextPosition position) {
    _position = position;
    if (_restorationOnly) {
      widget.onRestored?.call(widget.document.sections[_ordinal].title);
      return;
    }
    widget.onPosition(
      position,
      widget.document.progress(_section!, position),
      widget.document.sections[_ordinal].title,
    );
  }

  void _scrolled() {
    if (_selectionActive) return;
    if (_restoring ||
        _layout == null ||
        !_scroll.hasClients ||
        widget.settings.mode != ReadingMode.scroll) {
      return;
    }
    _manualNavigation();
    final y = _scroll.offset;
    final lines = _layout!.lines;
    if (y >= lines.last.globalTop + lines.last.height) {
      final end = _section!.end;
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

  TextStyle get _style => readerTextStyle(widget.settings, widget.foreground);

  Set<String> _figureIds(String sectionId) =>
      widget.figureBlocks[sectionId] ?? const {};

  Widget _figure(String blockId) =>
      widget.figureBuilder?.call(_section!.id, blockId) ??
      const SizedBox.shrink();

  SectionLayout _obtainLayout(
    text.TextSection section,
    double width,
    double height,
    TextScaler scaler,
  ) => _layouts.obtain(
    section: section,
    width: width,
    height: height,
    style: _style,
    scaler: scaler,
    committed: _layout,
    figureBlockIds: _figureIds(section.id),
  );

  void _prepare(double width, double height, TextScaler scaler) {
    final section = _section!;
    final style = _style;
    final key = (
      _layouts.keyFor(
        section: section,
        width: width,
        height: height,
        style: style,
        scaler: scaler,
        figureBlockIds: _figureIds(section.id),
      ),
      widget.settings.mode,
    );
    if (_layoutKey == key) return;
    _clearSelection();
    _turns.cancel();
    _width = width;
    _height = height;
    _scaler = scaler;
    final layout = _layouts.obtain(
      section: section,
      width: width,
      height: height,
      style: style,
      scaler: scaler,
      committed: _layout,
      figureBlockIds: _figureIds(section.id),
    );
    _layout = layout;
    _layoutKey = key;
    final position = section.resolve(_position ?? section.start);
    final line = layout.lineFor(position);
    _page = layout.pages.indexWhere((page) => page.contains(line));
    if (_page < 0) _page = 0;
    _restoring = true;
    final generation = ++_restoreGeneration;
    if (widget.settings.mode == ReadingMode.scroll) {
      // Seed a fresh scroll position before layout so its first painted frame
      // shows the anchor. PageStorage pixel offsets cannot override text anchors.
      final previous = _scroll;
      previous.removeListener(_scrolled);
      _scroll = ScrollController(
        initialScrollOffset: line.globalTop,
        keepScrollOffset: false,
      )..addListener(_scrolled);
      // The old scrollable detaches during this build; dispose only afterwards.
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _restoreGeneration) return;
      _restoring = false;
      // Keep the requested logical anchor during reflow. Reporting the page
      // start here would repeatedly drift backwards as typography changes.
      _report(position);
      _restorationOnly = false;
      final restored = _restored;
      _restored = null;
      if (restored != null && !restored.isCompleted) restored.complete();
    });
  }

  @override
  void dispose() {
    _clearSelection();
    if (_restored?.isCompleted == false) _restored!.complete();
    widget.navigation.detach(this);
    WidgetsBinding.instance.removeObserver(this);
    _turns.dispose();
    _scroll.dispose();
    _layouts.dispose();
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
        final reduceMotion = MediaQuery.disableAnimationsOf(context);
        _turns.reduceMotion = reduceMotion;
        _prepare(width, height, MediaQuery.textScalerOf(context));
        final layout = _layout!;
        final content = widget.settings.mode == ReadingMode.scroll
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _selectionActive ? null : widget.onTap,
                child: NotificationListener<OverscrollNotification>(
                  onNotification: (notification) {
                    if (_restoring || _selectionActive) return false;
                    if (notification.overscroll > 0) {
                      _advanceOrFinish();
                    } else if (notification.overscroll < 0) {
                      _previousEnd();
                    }
                    return false;
                  },
                  child: SingleChildScrollView(
                    key: ObjectKey(_scroll),
                    controller: _scroll,
                    physics: const ClampingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    child: ReaderSelectionContent(
                      onSelectedBlock: (block) => _selectedBlock = block,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: scrollSectionSlices(
                          layout,
                          sectionId: _section!.id,
                          activeNarrationRange: widget.activeNarrationRange,
                          figureBuilder: _figure,
                        ),
                      ),
                    ),
                  ),
                ),
              )
            : ReaderGestureSurface(
                mode: widget.settings.mode,
                selecting: _selectionActive,
                width: width,
                rightToLeft: _rightToLeft,
                onStep: _step,
                onTap: widget.onTap,
                onDragStart: (details) {
                  _manualNavigation();
                  _turns.dragStart(details);
                },
                onDragUpdate: _turns.dragUpdate,
                onDragCancel: _turns.dragCancel,
                onDragEnd: _turns.dragEnd,
                child: ClipRect(
                  child: SizedBox(
                    height: height,
                    width: width,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ReaderSelectionContent(
                          onSelectedBlock: (block) => _selectedBlock = block,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: textPageSlices(
                              layout.pages[_page],
                              sectionId: _section!.id,
                              activeNarrationRange: widget.activeNarrationRange,
                              figureBuilder: _figure,
                            ),
                          ),
                        ),
                        if (_turns.turn?.current case final current?)
                          ExcludeSemantics(
                            child: CustomPaint(
                              painter: PaperCurlPainter(
                                current: current,
                                target: _turns.turn!.incoming!,
                                turn: _turns.animation,
                                grabY: _turns.dragOrigin?.dy ?? _height / 2,
                                fingerY: _turns.dragPointer?.dy ?? _height / 2,
                                forward: _turns.turn!.delta > 0,
                                fromRight: !_rightToLeft,
                                paper: widget.background,
                              ),
                            ),
                          ),
                        if (_turns.error != null)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: Material(
                              color: widget.background,
                              child: TextButton(
                                onPressed: () => _step(_turns.delta),
                                child: const Text('Could not load page. Retry'),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
        return ReaderKeyNavigation(
          enabled: !_selectionActive,
          rightToLeft: _rightToLeft,
          onStep: _step,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            // Flutter's drag recognizer reports an accepted pointer cancellation
            // as a drag end. Handle it before the recognizer can commit a turn.
            child: Listener(
              onPointerCancel: (_) {
                if (widget.settings.mode == ReadingMode.pageFlip) {
                  _turns.dragCancel();
                }
              },
              // Navigation recognizers belong inside SelectionArea: an ordinary
              // touch swipe wins before its ancestor's text-drag recognizer,
              // while a stationary long press still starts native selection.
              child: ReaderSelectionRegion(
                key: _selection,
                onSelectionChanged: _selectionChanged,
                onReadFromHere: widget.onReadFromHere == null
                    ? null
                    : _readSelectedParagraph,
                child: content,
              ),
            ),
          ),
        );
      },
    );
  }
}
