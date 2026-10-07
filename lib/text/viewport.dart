import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import 'direction.dart';
import 'document.dart' as text;
import 'page_curl.dart';

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

  /// Number of turn textures owned by the viewport, for memory regressions.
  @visibleForTesting
  int get retainedTextureCount => _state?._turn?.current == null ? 0 : 2;

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

  /// Reports a leading passage and layout-independent progress. Curl previews
  /// never report: only completed turns may persist or unlock illustrations.
  final void Function(text.TextPosition position, double progress, String title)
  onPosition;

  /// Toggles reading chrome without intercepting drag navigation.
  final VoidCallback onTap;
  @override
  State<TextViewport> createState() => _TextViewportState();
}

class _TextViewportState extends State<TextViewport>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _animation;
  _PageTurn? _turn;
  int _turnEpoch = 0;
  bool _turnBusy = false;
  bool _dragAccepted = false;
  bool _dragging = false;
  double _dragDistance = 0;
  int _turnDelta = 1;
  bool _releaseComplete = false;
  bool _endOnly = false;
  Object? _turnError;
  double _width = 1, _height = 1;
  TextScaler _scaler = TextScaler.noScaling;
  bool _reduceMotion = false;
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
    WidgetsBinding.instance.addObserver(this);
    _animation = AnimationController(vsync: this)
      ..addListener(() {
        if (mounted) setState(() {});
      });
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
    if (oldWidget.settings != widget.settings ||
        oldWidget.foreground != widget.foreground ||
        oldWidget.background != widget.background) {
      _cancelTurn();
    }
    if (oldWidget.navigation != widget.navigation) {
      oldWidget.navigation._state = null;
      widget.navigation._state = this;
    }
  }

  Future<void> _goTo(text.TextPosition requested) async {
    final hadTurn = _turnBusy;
    _cancelTurn();
    if (hadTurn && mounted) setState(() {});
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
    if (widget.settings.mode != ReadingMode.scroll) {
      if (_turnBusy) return;
      if (widget.settings.mode == ReadingMode.pageFlip) {
        _startTurn(delta, automatic: true);
      } else {
        _immediatePage(delta);
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _cancelTurn();
      if (mounted) setState(() {});
    }
  }

  void _cancelTurn() {
    _turnEpoch++;
    _animation.stop();
    _turn?.dispose();
    _turn = null;
    _turnBusy = false;
    _dragAccepted = false;
    _dragging = false;
    _endOnly = false;
    _turnError = null;
  }

  // Adjacent pages use the same measured layout as the current viewport. A
  // generation token prevents chapter jumps/reflows accepting stale loads.
  Future<_PageTarget?> _resolvePage(int delta) async {
    final index = _page + delta;
    if (index >= 0 && index < _layout!.pages.length) {
      return _PageTarget(_ordinal, _section!, _layout!, index);
    }
    final ordinal = _ordinal + delta;
    if (ordinal < 0 || ordinal >= widget.document.sections.length) return null;
    final epoch = _turnEpoch;
    final section = await widget.store.loadSection(
      widget.sourcePath,
      widget.document.sections[ordinal].id,
    );
    if (!mounted || epoch != _turnEpoch) return null;
    final layout = _obtainLayout(section, _width, _height, _scaler);
    return _PageTarget(
      ordinal,
      section,
      layout,
      delta > 0 ? 0 : layout.pages.length - 1,
    );
  }

  void _commitPage(_PageTarget target) {
    setState(() {
      _ordinal = target.ordinal;
      _section = target.section;
      _layout = target.layout;
      _page = target.page;
      _layoutKey =
          '${_key(target.section, _width, _height, _scaler)}:${widget.settings.mode.name}';
    });
    _report(target.layout.pages[target.page].first.position(target.section.id));
  }

  Future<void> _immediatePage(int delta) async {
    final epoch = _turnEpoch;
    _turnBusy = true;
    try {
      final target = await _resolvePage(delta);
      if (!mounted || epoch != _turnEpoch) return;
      _turnBusy = false;
      if (target != null) {
        _commitPage(target);
      } else if (delta > 0) {
        _advanceOrFinish();
      }
    } on Object catch (error) {
      if (mounted && epoch == _turnEpoch) {
        setState(() {
          _turnBusy = false;
          _turnError = error;
          _turnDelta = delta;
        });
      }
    }
  }

  ui.Image _texture(_SectionLayout layout, int page) {
    final ratio = math.min(2.0, 2048 / math.max(_width, _height));
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(ratio);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, _width, _height),
      Paint()..color = widget.background,
    );
    final lines = layout.pages[page];
    var y = 0.0;
    var start = 0;
    while (start < lines.length) {
      var end = start + 1;
      while (end < lines.length && lines[end].block == lines[start].block) {
        end++;
      }
      final first = lines[start];
      final last = lines[end - 1];
      final height = last.top + last.height - first.top;
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, y, _width, height));
      first.block.painter.paint(canvas, Offset(0, y - first.top));
      canvas.restore();
      y += height + 16;
      start = end;
    }
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(
        (_width * ratio).ceil(),
        (_height * ratio).ceil(),
      );
    } finally {
      picture.dispose();
    }
  }

  Future<void> _startTurn(int delta, {required bool automatic}) async {
    if (_turnBusy || _layout == null || _restoring) return;
    final epoch = ++_turnEpoch;
    _turnBusy = true;
    _turnDelta = delta;
    _turnError = null;
    _animation.value = 0;
    ui.Image? current;
    try {
      final target = await _resolvePage(delta);
      if (!mounted || epoch != _turnEpoch) return;
      if (target == null) {
        _endOnly = true;
        if (automatic || !_dragging) _finishTurn(automatic || _releaseComplete);
        return;
      }
      if (_reduceMotion) {
        // Reduced motion keeps live paragraphs visible throughout the drag.
        _turn = _PageTurn(target, null, null, delta);
      } else {
        current = _texture(_layout!, _page);
        final incoming = _texture(target.layout, target.page);
        _turn = _PageTurn(target, current, incoming, delta);
        current = null; // Ownership transfers only after both textures exist.
      }
      // A drag may have ended during section I/O. Resume at its actual fraction
      // so settling still scales with the distance remaining, not loading time.
      if (!automatic) _animation.value = _dragProgress;
      if (automatic) {
        _settleTurn(true);
      } else if (!_dragging) {
        _settleTurn(_releaseComplete);
      } else {
        setState(() {});
      }
    } on Object catch (error) {
      current?.dispose();
      if (mounted && epoch == _turnEpoch) {
        _cancelTurn();
        setState(() {
          _turnError = error;
          _turnDelta = delta;
        });
      }
    }
  }

  double get _dragProgress => (_dragDistance.abs() / _width).clamp(0.0, 1.0);

  void _finishTurn(bool complete) {
    final target = _turn?.target;
    final end = _endOnly;
    final delta = _turnDelta;
    _cancelTurn();
    if (complete && target != null) {
      _commitPage(target);
    } else {
      setState(() {});
      if (complete && end && delta > 0) _advanceOrFinish();
    }
  }

  Future<void> _settleTurn(bool complete) async {
    if (_endOnly || _reduceMotion) {
      _finishTurn(complete);
      return;
    }
    if (_turn == null) return;
    final epoch = _turnEpoch;
    final target = complete ? 1.0 : 0.0;
    final duration = Duration(
      milliseconds: (300 * (target - _animation.value).abs()).round(),
    );
    try {
      await _animation
          .animateTo(target, duration: duration, curve: Curves.easeOutCubic)
          .orCancel;
    } on TickerCanceled {
      // Reflow, lifecycle changes, and explicit navigation keep the old anchor.
      return;
    }
    if (mounted && epoch == _turnEpoch) _finishTurn(complete);
  }

  void _dragStart(DragStartDetails details) {
    _dragAccepted = !_turnBusy && !_restoring;
    if (!_dragAccepted) return;
    _dragging = true;
    _dragDistance = 0;
    _releaseComplete = false;
  }

  void _dragUpdate(DragUpdateDetails details) {
    if (!_dragAccepted || !_dragging) return;
    final movement = details.primaryDelta ?? 0;
    if (!_turnBusy && movement != 0) {
      _turnDelta = (movement < 0) != widget.navigation.rightToLeft ? 1 : -1;
      _startTurn(_turnDelta, automatic: false);
    }
    final negative = (_turnDelta > 0) != widget.navigation.rightToLeft;
    _dragDistance = negative
        ? math.min(0, _dragDistance + movement)
        : math.max(0, _dragDistance + movement);
    if (_turn != null) setState(() => _animation.value = _dragProgress);
  }

  void _dragEnd(DragEndDetails details) {
    if (!_dragAccepted) return;
    _dragging = false;
    _dragAccepted = false;
    final velocity = details.primaryVelocity ?? 0;
    final negative = (_turnDelta > 0) != widget.navigation.rightToLeft;
    _releaseComplete =
        _dragProgress >= .35 ||
        (_dragDistance.abs() >= 8 &&
            velocity.abs() > 650 &&
            (velocity < 0) == negative);
    if (_turn != null || _endOnly) _settleTurn(_releaseComplete);
  }

  void _dragCancel() {
    if (!_dragAccepted) return;
    _dragging = false;
    _dragAccepted = false;
    _releaseComplete = false;
    if (_turn != null || _endOnly) _settleTurn(false);
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

  String _key(
    text.TextSection section,
    double width,
    double height,
    TextScaler scaler,
  ) =>
      '${section.id}:$width:$height:${widget.settings.fontSize}:${widget.settings.serif}:${widget.foreground.toARGB32()}:${scaler.scale(20)}';

  _SectionLayout _obtainLayout(
    text.TextSection section,
    double width,
    double height,
    TextScaler scaler,
  ) {
    final key = _key(section, width, height, scaler);
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
    // The committed layout remains alive while an adjacent section is previewed.
    while (_cache.length > 2) {
      final victim = _cache.keys.firstWhere(
        (key) => _cache[key] != _layout && _cache[key] != layout,
        orElse: () => _cache.keys.first,
      );
      _cache.remove(victim)!.dispose();
    }
    return layout;
  }

  void _prepare(double width, double height, TextScaler scaler) {
    final section = _section!;
    final key = _key(section, width, height, scaler);
    if (_layoutKey == '$key:${widget.settings.mode.name}') return;
    _cancelTurn();
    _width = width;
    _height = height;
    _scaler = scaler;
    final layout = _obtainLayout(section, width, height, scaler);
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
    WidgetsBinding.instance.removeObserver(this);
    _cancelTurn();
    _animation.dispose();
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
        final reduceMotion = MediaQuery.disableAnimationsOf(context);
        if (_reduceMotion != reduceMotion) _cancelTurn();
        _reduceMotion = reduceMotion;
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
                behavior: HitTestBehavior.opaque,
                onTapUp: widget.settings.mode == ReadingMode.pageFlip
                    ? (details) {
                        final fraction = details.localPosition.dx / width;
                        if (fraction < .2 || fraction > .8) {
                          _step(
                            (fraction > .8) != widget.navigation.rightToLeft
                                ? 1
                                : -1,
                          );
                        } else {
                          widget.onTap();
                        }
                      }
                    : (_) => widget.onTap(),
                onHorizontalDragStart:
                    widget.settings.mode == ReadingMode.pageFlip
                    ? _dragStart
                    : null,
                onHorizontalDragUpdate:
                    widget.settings.mode == ReadingMode.pageFlip
                    ? _dragUpdate
                    : null,
                onHorizontalDragCancel:
                    widget.settings.mode == ReadingMode.pageFlip
                    ? _dragCancel
                    : null,
                onHorizontalDragEnd:
                    widget.settings.mode == ReadingMode.pageFlip
                    ? _dragEnd
                    : (details) {
                        final velocity = details.primaryVelocity ?? 0;
                        if (velocity.abs() > 80) {
                          _step(
                            (velocity < 0) != widget.navigation.rightToLeft
                                ? 1
                                : -1,
                          );
                        }
                      },
                child: ClipRect(
                  child: SizedBox(
                    height: height,
                    width: width,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: _pageSlices(layout.pages[_page]),
                        ),
                        if (_turn?.current != null)
                          ExcludeSemantics(
                            child: CustomPaint(
                              painter: PaperCurlPainter(
                                current: _turn!.current!,
                                target: _turn!.incoming!,
                                progress: _animation.value,
                                forward: _turn!.delta > 0,
                                fromRight: !widget.navigation.rightToLeft,
                                paper: widget.background,
                              ),
                            ),
                          ),
                        if (_turnError != null)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: Material(
                              color: widget.background,
                              child: TextButton(
                                onPressed: () => _step(_turnDelta),
                                child: const Text('Could not load page. Retry'),
                              ),
                            ),
                          ),
                      ],
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
            // Flutter's drag recognizer reports an accepted pointer cancellation
            // as a drag end. Handle it before the recognizer can commit a turn.
            child: Listener(
              onPointerCancel: (_) {
                if (widget.settings.mode == ReadingMode.pageFlip) _dragCancel();
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.settings.mode == ReadingMode.scroll
                    ? widget.onTap
                    : null,
                child: content,
              ),
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

/// A resolved page owns no textures and shares the bounded section layout.
class _PageTarget {
  _PageTarget(this.ordinal, this.section, this.layout, this.page);
  final int ordinal, page;
  final text.TextSection section;
  final _SectionLayout layout;
}

/// Owns exactly two textures, or none when reduced motion is enabled.
class _PageTurn {
  _PageTurn(this.target, this.current, this.incoming, this.delta);
  final _PageTarget target;
  final ui.Image? current, incoming;
  final int delta;
  void dispose() {
    current?.dispose();
    incoming?.dispose();
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
