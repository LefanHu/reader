import 'dart:async';

import 'package:flutter/widgets.dart';

import '../app/reader_controller.dart';
import '../catalog/catalog_book.dart';
import '../narration/session.dart';
import '../text/narration_range.dart';
import '../text/reader_navigation.dart';
import '../text/text_position.dart';

/// Connects one open reader to the shared narration session.
///
/// It owns highlight ownership, spoken-text following and viewport restoration
/// for one book. It is not a notifier: rebuilds still come from the
/// controller's listener, which calls [sync].
class ReaderNarrationBinding {
  /// Creates a binding; [attach] must run before the first [sync].
  ReaderNarrationBinding({
    required this.controller,
    required this.book,
    required this.navigation,
    required this.isMounted,
    required this.isClosed,
  }) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    visible = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  /// Shared owner of the narration session and catalog.
  final ReaderController controller;

  /// Book displayed by the owning reader screen.
  final CatalogBook book;

  /// Viewport commands used to follow and restore the spoken passage.
  final TextReaderNavigation navigation;

  /// Whether the owning screen is still mounted.
  final bool Function() isMounted;

  /// Whether the owning screen is leaving.
  final bool Function() isClosed;

  /// Whether the app is foregrounded; hidden readers neither highlight nor follow.
  late bool visible;

  NarrationSession? _highlightSession;
  // Invalidates deferred presentation attachments on owner/lifecycle changes.
  int _highlightOwnerEpoch = 0;
  TextPosition? _pendingFollow;
  TextPosition? _narrationAnchor;
  bool _followScheduled = false;
  int _followEpoch = 0;
  int _revision = 0;
  bool _listening = false;

  /// Registers viewport restoration and claims highlight ownership.
  void attach() {
    controller.narration?.restoreViewport = _restoreViewport;
    _syncHighlightOwner();
  }

  Future<void> _restoreViewport(CatalogBook target, TextPosition anchor) async {
    if (!isMounted() || target.hash != book.hash) return;
    await navigation.restore(anchor);
  }

  void _syncHighlightOwner() {
    final session = controller.narration;
    final next = visible && !isClosed() && session?.book?.hash == book.hash
        ? session
        : null;
    if (identical(next, _highlightSession)) return;
    final previous = _highlightSession;
    _highlightSession = next;
    previous?.detachHighlightOwner(this);
    final epoch = ++_highlightOwnerEpoch;
    if (next == null) return;
    // Attaching can synchronously publish a newly visible cue. Reader creation
    // may be inside a controller builder, so never notify it during that build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isMounted() ||
          !visible ||
          isClosed() ||
          epoch != _highlightOwnerEpoch ||
          !identical(next, _highlightSession) ||
          !identical(next, controller.narration) ||
          next.book?.hash != book.hash) {
        return;
      }
      next.attachHighlightOwner(this);
    });
  }

  /// Reconciles highlight ownership, following and restoration after any
  /// controller or lifecycle change.
  void sync() {
    _syncHighlightOwner();
    final session = controller.narration;
    final listening = session?.ownsPosition(book) == true;
    final active = visible ? _anchorOf(session) : null;
    if (active != _narrationAnchor) {
      _narrationAnchor = active;
      _queueFollow(active);
    }
    if (active == null &&
        ((!_listening && listening) ||
            _revision != controller.narrationNavigationRevision)) {
      final anchor = controller.catalog.find(book)?.lastPosition;
      if (anchor != null) unawaited(navigation.restore(anchor));
    }
    _revision = controller.narrationNavigationRevision;
    _listening = listening;
  }

  /// Cancels any queued or running follow request.
  void stopFollowing() => _queueFollow(null);

  void _queueFollow(TextPosition? target) {
    ++_followEpoch;
    _pendingFollow = target;
    if (target == null || _followScheduled) return;
    _followScheduled = true;
    scheduleMicrotask(() async {
      try {
        while (isMounted() && _pendingFollow != null) {
          final next = _pendingFollow!;
          _pendingFollow = null;
          final epoch = _followEpoch;
          final session = controller.narration;
          await navigation.follow(
            next,
            isCurrent: () =>
                isMounted() &&
                !isClosed() &&
                visible &&
                epoch == _followEpoch &&
                identical(session, controller.narration) &&
                next == _anchorOf(controller.narration),
          );
        }
      } on Object catch (error, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'reader',
            context: ErrorDescription('while following spoken text'),
          ),
        );
      } finally {
        _followScheduled = false;
      }
    });
  }

  /// Spoken bounds to paint, only while this book plays in a visible reader.
  NarrationRange? get activeRange {
    final session = controller.narration;
    return session?.book?.hash == book.hash &&
            session?.status == NarrationStatus.playing &&
            visible
        ? session?.activeHighlight
        : null;
  }

  /// Spoken position the viewport should currently follow, if any.
  TextPosition? get liveAnchor =>
      visible ? _anchorOf(controller.narration) : null;

  /// Playing position of [session] when it narrates this book.
  TextPosition? _anchorOf(NarrationSession? session) =>
      session?.book?.hash == book.hash &&
          session?.status == NarrationStatus.playing
      ? session?.activeFollowPosition
      : null;

  /// Releases highlight ownership and cancels pending work.
  void dispose() {
    visible = false;
    ++_highlightOwnerEpoch;
    ++_followEpoch;
    _pendingFollow = null;
    _highlightSession?.detachHighlightOwner(this);
    _highlightSession = null;
    if (controller.narration?.restoreViewport == _restoreViewport) {
      controller.narration?.restoreViewport = null;
    }
  }
}
