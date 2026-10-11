import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle, LineMetrics;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'layout/measured_block.dart';

/// Provenance for joining adjacent slices without inventing text at leaf edges.
///
/// A selection container may insert paragraph separators between distinct block
/// IDs. Each leaf still returns only its exact normalized source substring.
abstract interface class BookTextSelectable implements Selectable {
  /// Stable normalized block identity, shared by all slices of that block.
  String get blockId;
}

/// Makes an already-painted visible block slice participate in SelectionArea.
///
/// Layout and prose paint remain the child's responsibility. The section owns
/// the borrowed painter: this proxy never lays it out, paints it, or disposes it.
class SelectableTextSlice extends SingleChildRenderObjectWidget {
  /// Borrows the source and measured geometry for [start, end).
  const SelectableTextSlice({
    super.key,
    required this.block,
    required this.top,
    required this.start,
    required this.end,
    required super.child,
  });

  /// Block and painter owned by the retained section layout.
  final MeasuredBlock block;

  /// Block-local top clipped away by the existing prose painter.
  final double top;

  /// Visible UTF-16 bounds, supplied at extended grapheme boundaries.
  final int start, end;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSelectableSlice(
        block,
        top,
        start,
        end,
        selectionColor:
            DefaultSelectionStyle.of(context).selectionColor ??
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
        registrar: SelectionContainer.maybeOf(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    final slice = renderObject as _RenderSelectableSlice;
    slice.updateSource(block, top, start, end);
    slice.selectionColor =
        DefaultSelectionStyle.of(context).selectionColor ??
        Theme.of(context).colorScheme.primary.withValues(alpha: 0.3);
    slice.registrar = SelectionContainer.maybeOf(context);
  }
}

/// Ephemeral selection in block-local offsets, projected into slice coordinates.
class _RenderSelectableSlice extends RenderProxyBox
    with Selectable, SelectionRegistrant
    implements BookTextSelectable {
  _RenderSelectableSlice(
    this._block,
    this._top,
    this._start,
    this._end, {
    required Color selectionColor,
    required SelectionRegistrar? registrar,
  }) : _selectionPaint = (Paint()..color = selectionColor) {
    _checkBounds();
    _geometry = SelectionGeometry(
      status: SelectionStatus.none,
      hasContent: contentLength > 0,
    );
    this.registrar = registrar;
  }

  MeasuredBlock _block;
  double _top;
  int _start, _end;
  TextPosition? _base, _extent;
  TextRange? _originBoundary;
  final Paint _selectionPaint;
  final _notifications = _SelectionNotifications();
  CharacterBoundary? _characterBoundary;
  ParagraphBoundary? _paragraphBoundary;
  List<LineMetrics>? _lineMetrics;
  SelectedContent? _selectedContent;
  late SelectionGeometry _geometry;
  List<Rect>? _boxes;
  LayerLink? _startLink, _endLink;
  final _startLayer = LayerHandle<LeaderLayer>();
  final _endLayer = LayerHandle<LeaderLayer>();
  bool _notificationPending = false;
  bool _disposed = false;

  String get _text => _block.block.text;
  TextPainter get _painter => _block.painter;
  CharacterBoundary get _characters =>
      _characterBoundary ??= CharacterBoundary(_text);
  ParagraphBoundary get _paragraphs =>
      _paragraphBoundary ??= ParagraphBoundary(_text);
  Rect get _clip => Offset.zero & size;

  @override
  String get blockId => _block.block.id;

  @override
  int get contentLength => _end - _start;

  @override
  SelectionGeometry get value => _geometry;

  @override
  bool get alwaysNeedsCompositing => _startLink != null || _endLink != null;

  void _checkBounds() {
    assert(_start >= 0 && _end >= _start && _end <= _text.length);
    assert(_characters.getLeadingTextBoundaryAt(_start) == _start);
    assert(_characters.getLeadingTextBoundaryAt(_end) == _end);
  }

  /// Reflow or slice replacement must not retain handles into an old painter.
  void updateSource(MeasuredBlock block, double top, int start, int end) {
    if (identical(_block, block) &&
        _top == top &&
        _start == start &&
        _end == end) {
      return;
    }
    if (!identical(_block, block)) {
      _characterBoundary = null;
      _paragraphBoundary = null;
      _lineMetrics = null;
    }
    _block = block;
    _top = top;
    _start = start;
    _end = end;
    _checkBounds();
    _boxes = null;
    _clear();
    _publish();
  }

  set selectionColor(Color color) {
    if (_selectionPaint.color == color) return;
    _selectionPaint.color = color;
    if (value.hasSelection) markNeedsPaint();
  }

  @override
  void addListener(VoidCallback listener) =>
      _notifications.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _notifications.removeListener(listener);

  @override
  void performLayout() {
    final Size? oldSize = hasSize ? size : null;
    super.performLayout();
    if (oldSize != size) {
      _boxes = null;
      _clear();
      _publish();
    }
  }

  @override
  List<Rect> get boundingBoxes => _boxes ??= _rects(_start, _end);

  List<Rect> _rects(int start, int end) {
    if (!hasSize || start == end) return const <Rect>[];
    final result = <Rect>[];
    for (final box in _painter.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
      boxHeightStyle: BoxHeightStyle.max,
    )) {
      final rect = box.toRect().shift(Offset(0, -_top)).intersect(_clip);
      if (rect.width >= 0 && rect.height > 0) result.add(rect);
    }
    return result;
  }

  Rect get _textRect {
    final boxes = boundingBoxes;
    if (boxes.isEmpty) return _clip;
    var result = boxes.first;
    for (var i = 1; i < boxes.length; i++) {
      result = result.expandToInclude(boxes[i]);
    }
    return result;
  }

  TextPosition _position(
    int offset, {
    TextAffinity? affinity,
    bool ceil = false,
  }) {
    offset = offset.clamp(_start, _end);
    final floor = _characters.getLeadingTextBoundaryAt(offset) ?? _start;
    if (floor != offset) {
      offset = ceil
          ? (_characters.getTrailingTextBoundaryAt(offset) ?? _end)
          : floor;
    }
    return TextPosition(
      offset: offset.clamp(_start, _end),
      affinity:
          affinity ??
          (offset == _end ? TextAffinity.upstream : TextAffinity.downstream),
    );
  }

  TextPosition _hit(Offset local) {
    final position = _painter.getPositionForOffset(local + Offset(0, _top));
    // The engine normally reports grapheme boundaries. Snap defensively without
    // ever letting a visible edge expose an invisible UTF-16 fragment.
    return _position(
      position.offset,
      affinity: position.affinity,
      ceil: position.affinity == TextAffinity.upstream,
    );
  }

  void _setEdge(TextPosition position, bool isEnd) {
    if (isEnd) {
      _extent = position;
    } else {
      _base = position;
    }
  }

  void _initialize(bool forward) {
    _extent ??= _position(forward ? _start : _end);
    _base ??= _extent;
  }

  void _clear() {
    _base = _extent = null;
    _originBoundary = null;
  }

  @override
  SelectedContent? getSelectedContent() {
    if (_base == null || _extent == null) return null;
    return _selectedContent ??= SelectedContent(
      plainText: _text.substring(
        math.min(_base!.offset, _extent!.offset),
        math.max(_base!.offset, _extent!.offset),
      ),
    );
  }

  @override
  SelectedContentRange? getSelection() {
    if (_base == null || _extent == null) return null;
    return SelectedContentRange(
      startOffset: _base!.offset - _start,
      endOffset: _extent!.offset - _start,
    );
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    if (!hasSize || contentLength == 0) return SelectionResult.none;
    final oldBase = _base;
    final oldExtent = _extent;
    final result = switch (event.type) {
      SelectionEventType.clear => _handleClear(),
      SelectionEventType.selectAll => _selectAll(),
      SelectionEventType.selectWord => _selectAt(
        (event as SelectWordSelectionEvent).globalPosition,
        TextGranularity.word,
      ),
      SelectionEventType.selectParagraph => _selectParagraph(
        event as SelectParagraphSelectionEvent,
      ),
      SelectionEventType.startEdgeUpdate || SelectionEventType.endEdgeUpdate =>
        _updateEdge(event as SelectionEdgeUpdateEvent),
      SelectionEventType.granularlyExtendSelection => _extendGranularly(
        event as GranularlyExtendSelectionEvent,
      ),
      SelectionEventType.directionallyExtendSelection => _extendDirectionally(
        event as DirectionallyExtendSelectionEvent,
      ),
    };
    if (_base != oldBase || _extent != oldExtent) _publish();
    return result;
  }

  SelectionResult _handleClear() {
    _clear();
    return SelectionResult.none;
  }

  SelectionResult _selectAll() {
    _base = _position(_start);
    _extent = _position(_end);
    _originBoundary = null;
    return SelectionResult.none;
  }

  TextRange _boundary(TextPosition position, TextGranularity granularity) {
    final offset = position.offset;
    final probe = TextPosition(
      offset: position.affinity == TextAffinity.upstream && offset > 0
          ? offset - 1
          : offset,
    );
    final range = switch (granularity) {
      TextGranularity.character => _characters.getTextBoundaryAt(probe.offset),
      TextGranularity.word => _painter.getWordBoundary(probe),
      TextGranularity.line => _painter.getLineBoundary(probe),
      TextGranularity.paragraph => _paragraphs.getTextBoundaryAt(probe.offset),
      TextGranularity.document => TextRange(start: 0, end: _text.length),
    };
    return TextRange(
      start: _position(range.start < 0 ? 0 : range.start).offset,
      end: _position(
        range.end < 0 ? _text.length : range.end,
        ceil: true,
      ).offset,
    );
  }

  SelectionResult _selectAt(Offset global, TextGranularity granularity) {
    final local = globalToLocal(global);
    final result = SelectionUtils.getResultBasedOnRect(_textRect, local);
    if (result != SelectionResult.end) return result;
    final position = _hit(local);
    if (granularity == TextGranularity.word &&
        _base != null &&
        _extent != null &&
        _base != _extent &&
        position.offset >= math.min(_base!.offset, _extent!.offset) &&
        position.offset <= math.max(_base!.offset, _extent!.offset)) {
      return SelectionResult.end;
    }
    final range = _boundary(position, granularity);
    _base = _position(range.start);
    _extent = _position(range.end);
    _originBoundary = range;
    return SelectionResult.end;
  }

  SelectionResult _selectParagraph(SelectParagraphSelectionEvent event) {
    if (event.absorb) {
      final range = _boundary(_position(_start), TextGranularity.paragraph);
      _base = _position(range.start);
      _extent = _position(range.end);
      _originBoundary = range;
      final fullEnd =
          _paragraphs.getTrailingTextBoundaryAt(_start) ?? _text.length;
      return fullEnd > _end ? SelectionResult.next : SelectionResult.end;
    }
    final result = _selectAt(event.globalPosition, TextGranularity.paragraph);
    if (result == SelectionResult.end &&
        _extent?.offset == _end &&
        _end < _text.length) {
      final fullEnd =
          _paragraphs.getTrailingTextBoundaryAt(_base!.offset) ?? _text.length;
      if (fullEnd > _end) return SelectionResult.next;
    }
    return result;
  }

  SelectionResult _updateEdge(SelectionEdgeUpdateEvent event) {
    final isEnd = event.type == SelectionEventType.endEdgeUpdate;
    final local = globalToLocal(event.globalPosition);
    final rect = _textRect;
    final screenResult = SelectionUtils.getResultBasedOnRect(rect, local);
    var position = _hit(
      SelectionUtils.adjustDragOffset(
        rect,
        local,
        direction: _painter.textDirection!,
      ),
    );
    // Outside the measured text, use logical bounds directly; bidi glyph runs
    // at a corner need not coincide with the logical paragraph start/end.
    if (screenResult != SelectionResult.end) {
      position = _position(
        screenResult == SelectionResult.previous ? _start : _end,
      );
    }
    if (event.granularity != TextGranularity.character) {
      final staticEdge = isEnd ? _base : _extent;
      final range = _boundary(position, event.granularity);
      if (staticEdge == null) {
        position = _position(
          position.offset - range.start < range.end - position.offset
              ? range.start
              : range.end,
        );
      } else {
        final origin = _originBoundary;
        if (origin != null) {
          // Keep the initially selected word/paragraph inside the selection even
          // when a desktop double/triple-click drag reverses over its anchor.
          if (isEnd) {
            final backwards = position.offset < origin.start;
            _base = _position(backwards ? origin.end : origin.start);
            position = _position(backwards ? range.start : range.end);
          } else {
            final forwards = position.offset > origin.end;
            _extent = _position(forwards ? origin.start : origin.end);
            position = _position(forwards ? range.end : range.start);
          }
        } else {
          position = _position(
            position.offset < staticEdge.offset ? range.start : range.end,
          );
        }
      }
    } else {
      _originBoundary = null;
    }
    _setEdge(position, isEnd);
    if (position.offset == _start) return SelectionResult.previous;
    if (position.offset == _end) return SelectionResult.next;
    return screenResult;
  }

  SelectionResult _extendGranularly(GranularlyExtendSelectionEvent event) {
    _originBoundary = null;
    _initialize(event.forward);
    final edge = event.isEnd ? _extent! : _base!;
    if (event.forward && edge.offset == _end) return SelectionResult.next;
    if (!event.forward && edge.offset == _start) {
      return SelectionResult.previous;
    }
    final int offset;
    switch (event.granularity) {
      case TextGranularity.character:
      case TextGranularity.word:
      case TextGranularity.paragraph:
      case TextGranularity.document:
        final TextBoundary boundary = switch (event.granularity) {
          TextGranularity.character => _characters,
          TextGranularity.word => _painter.wordBoundaries.moveByWordBoundary,
          TextGranularity.paragraph => _paragraphs,
          _ => DocumentBoundary(_text),
        };
        offset = event.forward
            ? boundary.getTrailingTextBoundaryAt(edge.offset) ?? _end
            : boundary.getLeadingTextBoundaryAt(edge.offset - 1) ?? _start;
      case TextGranularity.line:
        final range = _boundary(edge, TextGranularity.line);
        offset = event.forward ? range.end : range.start;
    }
    final position = _position(offset, ceil: event.forward);
    _setEdge(position, event.isEnd);
    if (event.granularity == TextGranularity.document) {
      return event.forward ? SelectionResult.next : SelectionResult.previous;
    }
    return SelectionResult.end;
  }

  SelectionResult _extendDirectionally(
    DirectionallyExtendSelectionEvent event,
  ) {
    _originBoundary = null;
    final forward =
        event.direction == SelectionExtendDirection.forward ||
        event.direction == SelectionExtendDirection.nextLine;
    _initialize(forward);
    final edge = event.isEnd ? _extent! : _base!;
    final caret = _painter.getOffsetForCaret(edge, Rect.zero);
    final dx = globalToLocal(Offset(event.dx, localToGlobal(Offset.zero).dy))
        .dx;
    final lines = _lineMetrics ??= _painter.computeLineMetrics();
    var current = lines.length - 1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].baseline > caret.dy) {
        current = i;
        break;
      }
    }
    final vertical =
        event.direction == SelectionExtendDirection.previousLine ||
        event.direction == SelectionExtendDirection.nextLine;
    var target = current;
    if (vertical) target += forward ? 1 : -1;
    TextPosition position;
    SelectionResult result = SelectionResult.end;
    if (target < 0 ||
        target >= lines.length ||
        (vertical &&
            (lines[target].baseline - lines[target].ascent < _top ||
                lines[target].baseline - lines[target].ascent >=
                    _top + size.height))) {
      position = _position(forward ? _end : _start);
      result = forward ? SelectionResult.next : SelectionResult.previous;
    } else {
      final line = lines[target];
      position = _hit(Offset(dx, line.baseline - line.ascent / 2 - _top));
      if (vertical && (position.offset == _start || position.offset == _end)) {
        result = position.offset == _start
            ? SelectionResult.previous
            : SelectionResult.next;
      }
    }
    _setEdge(position, event.isEnd);
    return result;
  }

  /// Resolve endpoints from their adjacent selected glyph runs, not only from
  /// paragraph direction, so mixed-direction passages get the correct handles.
  SelectionPoint _point(
    TextPosition position, {
    required bool leading,
    required bool collapsed,
  }) {
    if (!collapsed) {
      final adjacent = leading
          ? (_characters.getTrailingTextBoundaryAt(position.offset) ?? _end)
          : (_characters.getLeadingTextBoundaryAt(position.offset - 1) ??
                _start);
      final boxes = _painter.getBoxesForSelection(
        TextSelection(
          baseOffset: leading ? position.offset : adjacent,
          extentOffset: leading ? adjacent : position.offset,
        ),
      );
      if (boxes.isNotEmpty) {
        final box = leading ? boxes.first : boxes.last;
        final rtl = box.direction == TextDirection.rtl;
        return SelectionPoint(
          localPosition: Offset(
            leading ? box.start : box.end,
            box.bottom - _top,
          ),
          lineHeight: box.bottom - box.top,
          handleType: leading != rtl
              ? TextSelectionHandleType.left
              : TextSelectionHandleType.right,
        );
      }
    }
    final height = _painter.getFullHeightForCaret(position, Rect.zero);
    final caret = _painter.getOffsetForCaret(position, Rect.zero);
    return SelectionPoint(
      localPosition: caret + Offset(0, height - _top),
      lineHeight: height,
      handleType: collapsed
          ? TextSelectionHandleType.collapsed
          : (leading != (_painter.textDirection == TextDirection.rtl)
                ? TextSelectionHandleType.left
                : TextSelectionHandleType.right),
    );
  }

  void _publish() {
    _selectedContent = null;
    final base = _base;
    final extent = _extent;
    if (base == null || extent == null || !hasSize) {
      _geometry = SelectionGeometry(
        status: SelectionStatus.none,
        hasContent: contentLength > 0,
      );
    } else {
      final collapsed = base.offset == extent.offset;
      final reversed = base.offset > extent.offset;
      _geometry = SelectionGeometry(
        startSelectionPoint: _point(
          base,
          leading: !reversed,
          collapsed: collapsed,
        ),
        endSelectionPoint: _point(
          extent,
          leading: reversed,
          collapsed: collapsed,
        ),
        selectionRects: _rects(
          math.min(base.offset, extent.offset),
          math.max(base.offset, extent.offset),
        ),
        status: collapsed
            ? SelectionStatus.collapsed
            : SelectionStatus.uncollapsed,
        hasContent: contentLength > 0,
      );
    }
    markNeedsPaint();
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      // Reflow may replace the slice during build/layout. Defer only the
      // notification so selection overlays never rebuild inside that pipeline.
      if (!_notificationPending) {
        _notificationPending = true;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          _notificationPending = false;
          if (!_disposed) _notifyListeners();
        });
      }
    } else {
      _notifyListeners();
    }
  }

  void _notifyListeners() => _notifications.publish();

  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {
    if (_startLink == startHandle && _endLink == endHandle) return;
    _startLink = startHandle;
    _endLink = endHandle;
    markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  @override
  bool hitTestSelf(Offset position) => registrar != null;

  @override
  void paint(PaintingContext context, Offset offset) {
    context.canvas.save();
    context.canvas.clipRect(offset & size);
    for (final rect in value.selectionRects) {
      context.canvas.drawRect(rect.shift(offset), _selectionPaint);
    }
    context.canvas.restore();
    super.paint(context, offset);
    _paintHandle(
      context,
      offset,
      _startLink,
      value.startSelectionPoint,
      _startLayer,
    );
    _paintHandle(context, offset, _endLink, value.endSelectionPoint, _endLayer);
  }

  void _paintHandle(
    PaintingContext context,
    Offset offset,
    LayerLink? link,
    SelectionPoint? point,
    LayerHandle<LeaderLayer> handle,
  ) {
    if (link == null || point == null) {
      handle.layer = null;
      return;
    }
    final layer = handle.layer ??= LeaderLayer(link: link);
    layer.link = link;
    layer.offset = offset + point.localPosition;
    context.pushLayer(layer, _paintNothing, Offset.zero);
  }

  static void _paintNothing(PaintingContext context, Offset offset) {}

  @override
  void dispose() {
    _disposed = true;
    registrar = null;
    _notifications.dispose();
    // Containers clear cached handle owners after their leaves unmount. Release
    // links now so that this final null/null cleanup remains idempotent.
    _startLink = null;
    _endLink = null;
    _startLayer.layer = null;
    _endLayer.layer = null;
    // The section, not this proxy or its CustomPaint child, owns _painter.
    super.dispose();
  }
}

/// Owns reentrant listener notification without copying listeners each event.
class _SelectionNotifications extends ChangeNotifier {
  void publish() => notifyListeners();
}
