import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app/edge_back_gesture.dart';
import '../app/layout.dart';
import '../app/reader_controller.dart';
import '../catalog/catalog_book.dart';
import '../illustrations/illustration_scene.dart';
import '../illustrations/illustration_selection.dart';
import '../illustrations/illustration_setup.dart';
import '../narration/narration_sheet.dart';
import '../narration/status_indicator.dart';
import '../preferences/reading_mode.dart';
import '../text/document.dart' as text;
import '../text/document_store.dart' as text;
import '../text/text_contents_entry.dart' as text;
import '../text/reader_navigation.dart';
import '../text/viewport.dart';
import 'illustration_consent_dialog.dart';
import 'illustration_gallery.dart';
import 'illustration_reveal_dialog.dart';
import 'reader_contents_sheet.dart';
import 'reader_controls_transition.dart';
import 'reader_error.dart';
import 'reader_narration_binding.dart';
import 'reader_navigation_bar.dart';
import 'reader_settings_panel.dart';
import 'reader_toolbar.dart';

/// Flutter shell around the custom normalized text viewport.
/// The shell owns controls and consent; positions always refer to source text.
class ReaderScreen extends StatefulWidget {
  /// Creates a reader for [book] using the shared [controller].
  const ReaderScreen({
    super.key,
    required this.book,
    required this.controller,
    this.documentStore,
  });

  /// Catalog record containing the private source path and saved text position.
  final CatalogBook book;

  /// Owner of settings, illustration jobs, and progress persistence.
  final ReaderController controller;

  /// Optional document boundary for tests; production reads private sidecars.
  final text.TextDocumentStore? documentStore;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  late final Future<text.TextDocument> publication;
  final navigation = TextReaderNavigation();
  late final store = widget.documentStore ?? text.TextDocumentStore();
  bool controls = true;
  bool closed = false;
  bool revealingIllustration = false;
  String? chapterTitle;
  Timer? revealTimer;
  Timer? pollTimer;
  bool resumed = true;
  late final _narration = ReaderNarrationBinding(
    controller: widget.controller,
    book: widget.book,
    navigation: navigation,
    isMounted: () => mounted,
    isClosed: () => closed,
  );

  @override
  void initState() {
    super.initState();
    publication = _open();
    widget.controller.addListener(_controllerChanged);
    WidgetsBinding.instance.addObserver(this);
    _narration.attach();
    // Generation finishes while the reader rests on one anchor; polling uses
    // the committed position only and never writes to the viewport.
    pollTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _pollIllustrations(),
    );
  }

  Future<text.TextDocument> _open() => store.load(widget.book.path);

  void _pollIllustrations() {
    if (!mounted || closed || !resumed) return;
    if (!widget.controller.illustrations.manifestFor(widget.book).enabled) {
      return;
    }
    // Advance records auxiliary failures itself; polling never interrupts reading.
    widget.controller.illustrations.refresh(widget.book);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    resumed = state == AppLifecycleState.resumed;
    _narration.visible = resumed;
    _controllerChanged();
  }

  void _controllerChanged() {
    _narration.sync();
    _queueIllustrationReveal();
  }

  void _queueIllustrationReveal() {
    if (!mounted ||
        revealingIllustration ||
        widget.controller.illustrations.pendingRevealFor(widget.book) == null) {
      return;
    }
    revealTimer?.cancel();
    revealTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      final scene = widget.controller.illustrations.pendingRevealFor(
        widget.book,
      );
      if (scene != null) _showIllustration(scene);
    });
  }

  Future<void> _showIllustration(IllustrationScene scene) async {
    final path = scene.localImagePath;
    if (path == null || !File(path).existsSync() || revealingIllustration) {
      return;
    }
    revealingIllustration = true;
    await widget.controller.illustrations.markRevealed(widget.book, scene);
    if (!mounted) return;
    final action = await showDialog<IllustrationRevealAction>(
      context: context,
      barrierDismissible: false,
      builder: (context) => IllustrationRevealDialog(scene: scene),
    );
    if (action == IllustrationRevealAction.hide) {
      await widget.controller.illustrations.hide(widget.book, scene);
    } else if (action == IllustrationRevealAction.regenerate) {
      try {
        await widget.controller.illustrations.regenerate(widget.book, scene);
      } on Object catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(error.toString())));
        }
      }
    }
    revealingIllustration = false;
  }

  // Page textures and every control use the same app-wide opaque paper and ink.
  Color get _background => Theme.of(context).colorScheme.surface;
  Color get _foreground => Theme.of(context).colorScheme.onSurface;

  Future<void> _showToc(text.TextDocument pub) async {
    if (pub.contents.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This book has no table of contents.')),
      );
      return;
    }
    final choice = await showModalBottomSheet<text.TextContentsEntry>(
      context: context,
      isScrollControlled: true,
      builder: (context) => ReaderContentsSheet(contents: pub.contents),
    );
    if (choice?.position != null) navigation.goTo(choice!.position!);
  }

  Future<void> _showSettings() async {
    final panel = ReaderSettingsPanel(controller: widget.controller);
    // Match the library breakpoint: phones use a reachable bottom sheet while
    // wider tablet windows keep the current passage visible beside a panel.
    if (MediaQuery.sizeOf(context).width < wideLayoutMinWidth) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => SafeArea(child: panel),
      );
    } else {
      await showDialog<void>(
        context: context,
        barrierColor: Colors.black26,
        builder: (context) => Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 72, right: 20),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(width: 360, child: panel),
            ),
          ),
        ),
      );
    }
  }

  Future<void> _showIllustrations() async {
    final manifest = widget.controller.illustrations.manifestFor(widget.book);
    if (!manifest.enabled) {
      await _enableIllustrations();
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) =>
          IllustrationGallery(book: widget.book, controller: widget.controller),
    );
  }

  Future<void> _enableIllustrations() async {
    if (!widget.controller.illustrations.configured) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Illustrations are not configured'),
          content: const Text(
            'This build needs Firebase and the illustration API environment '
            'values before Google sign-in and generation can be used.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      return;
    }
    IllustrationSetup setup;
    try {
      setup = await widget.controller.illustrations.beginSetup(widget.book);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
      return;
    }
    if (!mounted) return;
    final selection = await showDialog<IllustrationSelection>(
      context: context,
      builder: (context) => IllustrationConsentDialog(setup: setup),
    );
    if (selection == null || !mounted) return;
    try {
      await widget.controller.illustrations.confirm(
        widget.book,
        setup: setup,
        selection: selection,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Illustrations enabled. Scenes will appear only after you read them.',
            ),
          ),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _close() async {
    // Back gestures and toolbar actions can race; flush only once on exit.
    final route = ModalRoute.of(context);
    if (closed || route?.isCurrent != true) return;
    closed = true;
    _narration.stopFollowing();
    _narration.sync();
    await widget.controller.flush();
    if (!mounted) return;
    // A sheet opened during persistence belongs to a different exit action.
    if (route!.isCurrent) {
      Navigator.pop(context);
    } else {
      closed = false;
      _controllerChanged();
    }
  }

  @override
  void dispose() {
    revealTimer?.cancel();
    pollTimer?.cancel();
    widget.controller.removeListener(_controllerChanged);
    _narration.dispose();
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.flush();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _close();
    },
    child: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => EdgeBackGesture(
        onBack: _close,
        child: Scaffold(
          backgroundColor: _background,
          body: SafeArea(
            child: FutureBuilder<text.TextDocument>(
              future: publication,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return ReaderError(
                    message: snapshot.error.toString(),
                    onBack: _close,
                  );
                }
                final pub = snapshot.data;
                if (pub == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                return Column(
                  children: [
                    // Both control areas remain reserved. Changing these heights
                    // would reflow text and interrupt a page curl when chrome toggles.
                    SizedBox(
                      height: ReaderToolbar.height,
                      child: Stack(
                        children: [
                          ReaderControlsTransition(
                            visible: controls,
                            hiddenOffset: const Offset(0, -.15),
                            child: ReaderToolbar(
                              title: chapterTitle ?? widget.book.title,
                              foreground: _foreground,
                              illustrationCount: widget.controller.illustrations
                                  .manifestFor(widget.book)
                                  .unlockedScenes
                                  .length,
                              onBack: _close,
                              onToc: () => _showToc(pub),
                              onIllustrations: _showIllustrations,
                              onListen: () => showNarrationSheet(
                                context,
                                widget.controller,
                                widget.book,
                              ),
                              onSettings: _showSettings,
                              onHide: () => setState(() => controls = false),
                            ),
                          ),
                          ReaderControlsTransition(
                            visible: !controls,
                            child: SizedBox(
                              height: ReaderToolbar.height,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: IconButton(
                                  tooltip: 'Show reading controls',
                                  color: _foreground,
                                  onPressed: () =>
                                      setState(() => controls = true),
                                  icon: const Icon(Icons.visibility_outlined),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      // Keep the same viewport element through control transitions.
                      key: const ValueKey('reading-content'),
                      child: Center(
                        child: ConstrainedBox(
                          // Long lines reduce readability, especially on iPad.
                          constraints: const BoxConstraints(maxWidth: 680),
                          child: _readerView(pub),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: ReaderNavigationBar.height,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          ReaderControlsTransition(
                            visible: controls,
                            hiddenOffset: const Offset(0, .15),
                            child: ReaderNavigationBar(
                              listeningStatus: controls
                                  ? _narrationStatus()
                                  : null,
                              progress:
                                  widget.controller.catalog
                                      .find(widget.book)
                                      ?.progress ??
                                  widget.book.progress,
                              foreground: _foreground,
                              pages:
                                  widget.controller.preferences.settings.mode !=
                                  ReadingMode.scroll,
                              rightToLeft: navigation.rightToLeft,
                              onPrevious: navigation.previous,
                              onNext: navigation.next,
                              onPreviousChapter: navigation.previousSection,
                              onNextChapter: navigation.nextSection,
                            ),
                          ),
                          if (!controls)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                              ),
                              child: _narrationStatus(),
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );

  Widget? _narrationStatus() {
    final session = widget.controller.narration;
    if (session?.book?.hash != widget.book.hash || session?.ready != true) {
      return null;
    }
    return NarrationStatusIndicator(
      key: const ValueKey('reader-narration-status'),
      status: session!.status,
    );
  }

  Widget _readerView(text.TextDocument document) {
    final liveAnchor = _narration.liveAnchor;
    return TextViewport(
      document: document,
      sourcePath: widget.book.path,
      store: store,
      navigation: navigation,
      settings: widget.controller.preferences.settings,
      foreground: _foreground,
      background: _background,
      activeNarrationRange: _narration.activeRange,
      // Live spoken bounds reopen as presentation, never durable progress.
      initialPositionIsRestoration: liveAnchor != null,
      initialPosition:
          liveAnchor ??
          widget.controller.catalog.find(widget.book)?.lastPosition ??
          widget.book.lastPosition,
      onRestored: (title) {
        if (mounted && chapterTitle != title) {
          setState(() => chapterTitle = title);
        }
      },
      onManualNavigation: () {
        unawaited(widget.controller.narration?.navigate(widget.book));
      },
      onReadFromHere: widget.controller.narration == null
          ? null
          : (position) => unawaited(
              showNarrationSheet(
                context,
                widget.controller,
                widget.book,
                start: position,
              ),
            ),
      onTap: () => setState(() => controls = !controls),
      onPosition: (position, progress, title) {
        widget.controller.savePosition(widget.book, position, progress);
        if (chapterTitle != title && mounted) {
          setState(() => chapterTitle = title);
        }
      },
    );
  }
}
