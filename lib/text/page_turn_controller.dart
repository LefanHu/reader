import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../generation_fence.dart';
import 'page_target.dart';
import 'page_turn.dart';

/// Loads the page [delta] steps from the committed one, or null past either
/// end of the book. Once [ticket] is stale it must return null without
/// obtaining a layout, so a superseded load never evicts a retained one.
typedef PageResolver = Future<PageTarget?> Function(
  int delta,
  FenceTicket ticket,
);

/// Page-mode turn state machine of the text viewport: drag tracking, the
/// curl animation and the single in-flight [PageTurn].
///
/// Curl previews never report positions; only completed turns reach
/// [commit]. [cancel] (reflow, navigation, selection, suspension, disposal)
/// retires every pending load and releases both textures synchronously.
class PageTurnController {
  /// Callbacks borrow the viewport's committed layout; this controller owns
  /// only the animation and the textures of the active turn.
  PageTurnController({
    required TickerProvider vsync,
    required this.ready,
    required this.committed,
    required this.resolve,
    required this.texture,
    required this.commit,
    required this.pastEnd,
    required this.rightToLeft,
    required this.width,
    required this.changed,
  }) : animation = AnimationController(vsync: vsync);

  /// Whether a committed layout exists and no restoration is in progress.
  final bool Function() ready;

  /// The page currently shown, used for the outgoing curl texture.
  final PageTarget Function() committed;

  /// Loads adjacent pages; see [PageResolver].
  final PageResolver resolve;

  /// Rasterizes one page; the caller owns the returned image.
  final ui.Image Function(PageTarget page) texture;

  /// Commits a completed turn and reports its position.
  final void Function(PageTarget target) commit;

  /// Completing a forward turn past the last page of the section or book.
  final VoidCallback pastEnd;

  /// Whether the committed section reads right to left; swipes mirror.
  final bool Function() rightToLeft;

  /// Page width in logical pixels, the full drag distance of a turn.
  final double Function() width;

  /// Requests a rebuild when the curl layer, retry banner or drag changes.
  final VoidCallback changed;

  /// Turn progress from 0 (committed page) to 1 (target page). The curl
  /// painter listens directly, so frames repaint only that layer.
  final AnimationController animation;

  final _fence = GenerationFence();
  PageTurn? _turn;
  bool _busy = false;
  bool _dragAccepted = false;
  bool _dragging = false;
  double _dragDistance = 0;
  // Page-local coordinates survive release and section I/O until [cancel].
  Offset? _dragOrigin;
  Offset? _dragPointer;
  int _delta = 1;
  bool _releaseComplete = false;
  bool _endOnly = false;
  Object? _error;
  bool _reduceMotion = false;

  /// The in-flight turn with its two-or-zero textures.
  PageTurn? get turn => _turn;

  /// Whether a turn or immediate page load is in progress.
  bool get busy => _busy;

  /// Failure of the last page load, shown with a retry action.
  Object? get error => _error;

  /// Direction of the last attempted turn, retried after [error].
  int get delta => _delta;

  /// Where the active drag grabbed the page, if it is a drag.
  Offset? get dragOrigin => _dragOrigin;

  /// Latest pointer position of the active drag.
  Offset? get dragPointer => _dragPointer;

  /// Reduced motion turns without textures; changing it cancels a turn.
  set reduceMotion(bool value) {
    if (_reduceMotion != value) cancel();
    _reduceMotion = value;
  }

  /// Abandons any turn without committing, keeping the old anchor.
  void cancel() {
    _fence.invalidate();
    animation.stop();
    _turn?.dispose();
    _turn = null;
    _busy = false;
    _dragAccepted = false;
    _dragging = false;
    _dragOrigin = null;
    _dragPointer = null;
    _endOnly = false;
    _error = null;
  }

  /// Steps one page: [animated] curls automatically, otherwise the adjacent
  /// page commits as soon as it loads.
  void step(int delta, {required bool animated}) {
    if (_busy) return;
    if (animated) {
      _start(delta, automatic: true);
    } else {
      _immediate(delta);
    }
  }

  Future<void> _immediate(int delta) async {
    final ticket = _fence.capture();
    _busy = true;
    try {
      final target = await resolve(delta, ticket);
      if (!ticket.isCurrent) return;
      _busy = false;
      if (target != null) {
        commit(target);
      } else if (delta > 0) {
        pastEnd();
      }
    } on Object catch (error) {
      if (ticket.isCurrent) {
        _busy = false;
        _error = error;
        _delta = delta;
        changed();
      }
    }
  }

  Future<void> _start(int delta, {required bool automatic}) async {
    if (_busy || !ready()) return;
    if (automatic) {
      _dragOrigin = null;
      _dragPointer = null;
    }
    _fence.invalidate();
    final ticket = _fence.capture();
    _busy = true;
    _delta = delta;
    _error = null;
    animation.value = 0;
    changed();
    ui.Image? current;
    try {
      final target = await resolve(delta, ticket);
      if (!ticket.isCurrent) return;
      if (target == null) {
        _endOnly = true;
        if (automatic || !_dragging) _finish(automatic || _releaseComplete);
        return;
      }
      if (_reduceMotion) {
        // Reduced motion keeps live paragraphs visible throughout the drag.
        _turn = PageTurn(target, null, null, delta);
      } else {
        current = texture(committed());
        final incoming = texture(target);
        _turn = PageTurn(target, current, incoming, delta);
        current = null; // Ownership transfers only after both textures exist.
      }
      // A drag may have ended during section I/O. Resume at its actual fraction
      // so settling still scales with the distance remaining, not loading time.
      if (!automatic) animation.value = _progress;
      changed();
      if (automatic) {
        _settle(true);
      } else if (!_dragging) {
        _settle(_releaseComplete);
      }
    } on Object catch (error) {
      current?.dispose();
      if (ticket.isCurrent) {
        cancel();
        _error = error;
        _delta = delta;
        changed();
      }
    }
  }

  double get _progress => (_dragDistance.abs() / width()).clamp(0.0, 1.0);

  void _finish(bool complete) {
    final target = _turn?.target;
    final end = _endOnly;
    final delta = _delta;
    cancel();
    if (complete && target != null) {
      commit(target);
    } else {
      changed();
      if (complete && end && delta > 0) pastEnd();
    }
  }

  Future<void> _settle(bool complete) async {
    if (_endOnly || _reduceMotion) {
      _finish(complete);
      return;
    }
    if (_turn == null) return;
    final ticket = _fence.capture();
    final target = complete ? 1.0 : 0.0;
    final duration = Duration(
      milliseconds: (300 * (target - animation.value).abs()).round(),
    );
    try {
      await animation
          .animateTo(target, duration: duration, curve: Curves.easeOutCubic)
          .orCancel;
    } on TickerCanceled {
      // Reflow, lifecycle changes, and explicit navigation keep the old anchor.
      return;
    }
    if (ticket.isCurrent) _finish(complete);
  }

  /// Accepts a drag only while idle and ready.
  void dragStart(DragStartDetails details) {
    _dragAccepted = !_busy && ready();
    if (!_dragAccepted) return;
    _dragging = true;
    _dragDistance = 0;
    _dragOrigin = details.localPosition;
    _dragPointer = details.localPosition;
    _releaseComplete = false;
  }

  /// The first movement picks the logical direction and starts loading.
  void dragUpdate(DragUpdateDetails details) {
    if (!_dragAccepted || !_dragging) return;
    _dragPointer = details.localPosition;
    final movement = _dragPointer!.dx - _dragOrigin!.dx;
    if (!_busy && movement != 0) {
      _delta = (movement < 0) != rightToLeft() ? 1 : -1;
      _start(_delta, automatic: false);
    }
    final negative = (_delta > 0) != rightToLeft();
    _dragDistance = negative ? math.min(0, movement) : math.max(0, movement);
    if (_turn != null) {
      animation.value = _progress;
      changed();
    }
  }

  /// Completes past 35% or on a fling in the turn's direction.
  void dragEnd(DragEndDetails details) {
    if (!_dragAccepted) return;
    _dragging = false;
    _dragAccepted = false;
    final velocity = details.primaryVelocity ?? 0;
    final negative = (_delta > 0) != rightToLeft();
    _releaseComplete =
        _progress >= .35 ||
        (_dragDistance.abs() >= 8 &&
            velocity.abs() > 650 &&
            (velocity < 0) == negative);
    if (_turn != null || _endOnly) _settle(_releaseComplete);
  }

  /// A cancelled pointer always settles back to the committed page.
  void dragCancel() {
    if (!_dragAccepted) return;
    _dragging = false;
    _dragAccepted = false;
    _releaseComplete = false;
    if (_turn != null || _endOnly) _settle(false);
  }

  /// Cancels the turn and releases the animation.
  void dispose() {
    cancel();
    animation.dispose();
  }
}
