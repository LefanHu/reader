import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'text/document.dart' as text;
import 'text/viewport.dart';

import 'controller.dart';
import 'illustrations/api.dart';
import 'illustrations/models.dart';
import 'models.dart';
import 'theme.dart';

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

class _ReaderScreenState extends State<ReaderScreen> {
  late final Future<text.TextDocument> publication;
  final navigation = TextReaderNavigation();
  late final store = widget.documentStore ?? text.TextDocumentStore();
  bool controls = true;
  bool closed = false;
  bool revealingIllustration = false;
  String? chapterTitle;
  Timer? revealTimer;

  @override
  void initState() {
    super.initState();
    publication = _open();
    widget.controller.addListener(_controllerChanged);
  }

  Future<text.TextDocument> _open() => store.load(widget.book.path);

  void _controllerChanged() => _queueIllustrationReveal();

  void _queueIllustrationReveal() {
    if (!mounted ||
        revealingIllustration ||
        widget.controller.pendingRevealFor(widget.book) == null) {
      return;
    }
    revealTimer?.cancel();
    revealTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      final scene = widget.controller.pendingRevealFor(widget.book);
      if (scene != null) _showIllustration(scene);
    });
  }

  Future<void> _showIllustration(IllustrationScene scene) async {
    final path = scene.localImagePath;
    if (path == null || !File(path).existsSync() || revealingIllustration) {
      return;
    }
    revealingIllustration = true;
    await widget.controller.markIllustrationRevealed(widget.book, scene);
    if (!mounted) return;
    final action = await showDialog<_IllustrationAction>(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                image: true,
                label: scene.altText ?? 'Generated scene illustration',
                child: Image.file(File(path), fit: BoxFit.contain),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  scene.caption?.isNotEmpty == true
                      ? scene.caption!
                      : 'A scene you just read',
                  style: const TextStyle(
                    fontFamily: 'Lora',
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () =>
                          Navigator.pop(context, _IllustrationAction.hide),
                      child: const Text('Hide'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(
                        context,
                        _IllustrationAction.regenerate,
                      ),
                      child: const Text('Regenerate'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(
                        context,
                        _IllustrationAction.continueReading,
                      ),
                      child: const Text('Continue reading'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (action == _IllustrationAction.hide) {
      await widget.controller.hideIllustration(widget.book, scene);
    } else if (action == _IllustrationAction.regenerate) {
      await widget.controller.regenerateIllustration(widget.book, scene);
    }
    revealingIllustration = false;
  }

  Color get _background => switch (widget.controller.settings.theme) {
    ReadingTheme.paper => const Color(0xFFF7F4ED),
    ReadingTheme.sepia => const Color(0xFFF0E1C2),
    ReadingTheme.dark => const Color(0xFF171A18),
  };

  Color get _foreground => widget.controller.settings.theme == ReadingTheme.dark
      ? const Color(0xFFE8E3D8)
      : ink;

  Future<void> _showToc(text.TextDocument pub) async {
    final items = <({text.TextContentsEntry link, int depth})>[];
    // Flatten only for presentation, retaining resolved fragment targets.
    void add(List<text.TextContentsEntry> links, int depth) {
      for (final link in links) {
        items.add((link: link, depth: depth));
        add(link.children, depth + 1);
      }
    }

    add(pub.contents, 0);
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This book has no table of contents.')),
      );
      return;
    }
    final choice = await showModalBottomSheet<text.TextContentsEntry>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .72,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'Contents',
                  style: TextStyle(
                    fontFamily: 'Lora',
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  children: items
                      .map(
                        (item) => ListTile(
                          contentPadding: EdgeInsets.only(
                            left: 20 + item.depth * 20.0,
                            right: 20,
                          ),
                          title: Text(item.link.title),
                          onTap: item.link.position == null
                              ? null
                              : () => Navigator.pop(context, item.link),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice?.position != null) navigation.goTo(choice!.position!);
  }

  Future<void> _showSettings() async {
    final panel = _SettingsPanel(controller: widget.controller);
    // Match the library breakpoint: phones use a reachable bottom sheet while
    // wider tablet windows keep the current passage visible beside a panel.
    if (MediaQuery.sizeOf(context).width < 700) {
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
    final manifest = widget.controller.manifestFor(widget.book);
    if (!manifest.enabled) {
      await _enableIllustrations();
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _IllustrationGallery(
        book: widget.book,
        controller: widget.controller,
      ),
    );
  }

  Future<void> _enableIllustrations() async {
    if (!widget.controller.illustrationsConfigured) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Illustrations are not configured'),
          content: const Text(
            'This build needs Firebase and the illustration API environment '
            'values before Sign in with Apple and generation can be used.',
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
      setup = await widget.controller.beginIllustrationSetup(widget.book);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
      return;
    }
    if (!mounted) return;
    final style = await showDialog<String>(
      context: context,
      builder: (context) => _IllustrationConsentDialog(setup: setup),
    );
    if (style == null || !mounted) return;
    try {
      await widget.controller.confirmIllustrations(
        widget.book,
        setup: setup,
        style: style,
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
    if (closed) return;
    closed = true;
    await widget.controller.flush();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    revealTimer?.cancel();
    widget.controller.removeListener(_controllerChanged);
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
      builder: (context, _) => Scaffold(
        backgroundColor: _background,
        body: SafeArea(
          child: FutureBuilder<text.TextDocument>(
            future: publication,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return _ReaderError(
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
                    height: 60,
                    child: Stack(
                      children: [
                        _ControlsTransition(
                          visible: controls,
                          hiddenOffset: const Offset(0, -.15),
                          child: _Toolbar(
                            title: chapterTitle ?? widget.book.title,
                            foreground: _foreground,
                            illustrationCount: widget.controller
                                .manifestFor(widget.book)
                                .unlockedScenes
                                .length,
                            onBack: _close,
                            onToc: () => _showToc(pub),
                            onIllustrations: _showIllustrations,
                            onSettings: _showSettings,
                            onHide: () => setState(() => controls = false),
                          ),
                        ),
                        _ControlsTransition(
                          visible: !controls,
                          child: SizedBox(
                            height: 60,
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
                    height: 62,
                    child: _ControlsTransition(
                      visible: controls,
                      hiddenOffset: const Offset(0, .15),
                      child: _NavigationBar(
                        progress:
                            widget.controller.books
                                .where((book) => book.hash == widget.book.hash)
                                .firstOrNull
                                ?.progress ??
                            widget.book.progress,
                        foreground: _foreground,
                        pages:
                            widget.controller.settings.mode !=
                            ReadingMode.scroll,
                        rightToLeft: navigation.rightToLeft,
                        onPrevious: navigation.previous,
                        onNext: navigation.next,
                        onPreviousChapter: navigation.previousSection,
                        onNextChapter: navigation.nextSection,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _readerView(text.TextDocument document) => TextViewport(
    document: document,
    sourcePath: widget.book.path,
    store: store,
    navigation: navigation,
    settings: widget.controller.settings,
    foreground: _foreground,
    background: _background,
    initialPosition: widget.book.lastPosition,
    onTap: () => setState(() => controls = !controls),
    onPosition: (position, progress, title) {
      widget.controller.savePosition(widget.book, position, progress);
      if (chapterTitle != title && mounted) {
        setState(() => chapterTitle = title);
      }
    },
  );
}

/// Animates chrome inside fixed slots without changing viewport constraints.
/// Hidden controls stop accepting input, focus, and semantics immediately,
/// even while their last visible pixels are still fading out.
class _ControlsTransition extends StatelessWidget {
  const _ControlsTransition({
    required this.visible,
    required this.child,
    this.hiddenOffset = Offset.zero,
  });
  final bool visible;
  final Widget child;
  final Offset hiddenOffset;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    return ClipRect(
      child: IgnorePointer(
        ignoring: !visible,
        child: ExcludeSemantics(
          excluding: !visible,
          child: ExcludeFocus(
            excluding: !visible,
            child: AnimatedSlide(
              offset: visible ? Offset.zero : hiddenOffset,
              duration: duration,
              curve: Curves.easeOut,
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: duration,
                curve: Curves.easeOut,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Top reader controls for leaving, navigating, configuring, and hiding chrome.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.title,
    required this.foreground,
    required this.illustrationCount,
    required this.onBack,
    required this.onToc,
    required this.onIllustrations,
    required this.onSettings,
    required this.onHide,
  });
  final String title;
  final Color foreground;
  final int illustrationCount;
  final VoidCallback onBack, onToc, onIllustrations, onSettings, onHide;
  @override
  Widget build(BuildContext context) => IconTheme(
    data: IconThemeData(color: foreground),
    child: SizedBox(
      height: 60,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back to library',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
          ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: foreground,
                fontFamily: 'Lora',
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Choose chapter',
            onPressed: onToc,
            icon: const Icon(Icons.list_alt),
          ),
          Badge(
            isLabelVisible: illustrationCount > 0,
            label: Text('$illustrationCount'),
            child: IconButton(
              tooltip: 'AI illustrations',
              onPressed: onIllustrations,
              icon: const Icon(Icons.auto_awesome_outlined),
            ),
          ),
          IconButton(
            tooltip: 'Reading settings',
            onPressed: onSettings,
            icon: const Icon(Icons.text_fields),
          ),
          IconButton(
            tooltip: 'Hide reading controls',
            onPressed: onHide,
            icon: const Icon(Icons.visibility_off_outlined),
          ),
        ],
      ),
    ),
  );
}

enum _IllustrationAction { continueReading, hide, regenerate }

/// Consent and art-direction confirmation before any prose leaves the device.
class _IllustrationConsentDialog extends StatefulWidget {
  const _IllustrationConsentDialog({required this.setup});
  final IllustrationSetup setup;

  @override
  State<_IllustrationConsentDialog> createState() =>
      _IllustrationConsentDialogState();
}

class _IllustrationConsentDialogState
    extends State<_IllustrationConsentDialog> {
  late String style = widget.setup.suggestedStyle;

  @override
  Widget build(BuildContext context) {
    final styles = <String>{
      widget.setup.suggestedStyle,
      ...widget.setup.alternativeStyles,
    }.toList();
    return AlertDialog(
      title: const Text('Illustrate this book?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Reader sends only the current and next chapter’s normalized '
              'text to the private generation service. The source book is never '
              'uploaded or changed, and art stays locked until you pass the '
              'scene it depicts.',
            ),
            const SizedBox(height: 16),
            Text(
              'Estimated maximum: ${widget.setup.estimatedCredits} credits '
              'for this book. Credits are charged only for completed images.',
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: style,
              decoration: const InputDecoration(labelText: 'Art direction'),
              items: styles
                  .map(
                    (item) => DropdownMenuItem(value: item, child: Text(item)),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => style = value);
              },
            ),
            const SizedBox(height: 12),
            const Text(
              'Sign in with Apple is used to protect generation credits. '
              'Reading remains available offline and without an account.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, style),
          child: const Text('Enable illustrations'),
        ),
      ],
    );
  }
}

/// Unlocked-only gallery; queued and locked scenes have no revealing UI.
class _IllustrationGallery extends StatelessWidget {
  const _IllustrationGallery({required this.book, required this.controller});

  final CatalogBook book;
  final ReaderController controller;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .78,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final scenes = controller.manifestFor(book).unlockedScenes;
          return Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Text(
                  'Illustrated scenes',
                  style: TextStyle(
                    fontFamily: 'Lora',
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: scenes.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text(
                            'Scenes will appear here after you read past them.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(16),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 360,
                              childAspectRatio: 1.15,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                            ),
                        itemCount: scenes.length,
                        itemBuilder: (context, index) {
                          final scene = scenes[index];
                          final path =
                              scene.localThumbnailPath ?? scene.localImagePath;
                          return Card(
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: path == null
                                  ? null
                                  : () => _showScene(context, scene),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child:
                                        path != null && File(path).existsSync()
                                        ? Semantics(
                                            image: true,
                                            label:
                                                scene.altText ??
                                                'Generated scene illustration',
                                            child: Image.file(
                                              File(path),
                                              fit: BoxFit.cover,
                                            ),
                                          )
                                        : const Center(
                                            child: Icon(Icons.broken_image),
                                          ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Text(
                                      scene.caption?.isNotEmpty == true
                                          ? scene.caption!
                                          : 'Scene illustration',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    ),
  );

  Future<void> _showScene(BuildContext context, IllustrationScene scene) async {
    final path = scene.localImagePath;
    if (path == null || !File(path).existsSync()) return;
    final action = await showDialog<_IllustrationAction>(
      context: context,
      builder: (context) => AlertDialog(
        contentPadding: EdgeInsets.zero,
        content: Semantics(
          image: true,
          label: scene.altText ?? 'Generated scene illustration',
          child: Image.file(File(path), fit: BoxFit.contain),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _IllustrationAction.hide),
            child: const Text('Delete'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, _IllustrationAction.regenerate),
            child: const Text('Regenerate'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _IllustrationAction.continueReading),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (action == _IllustrationAction.hide) {
      await controller.deleteIllustration(book, scene);
    } else if (action == _IllustrationAction.regenerate) {
      await controller.regenerateIllustration(book, scene);
    }
  }
}

/// Accessible page/chapter controls and publication-wide progress display.
class _NavigationBar extends StatelessWidget {
  const _NavigationBar({
    required this.progress,
    required this.foreground,
    required this.pages,
    required this.rightToLeft,
    required this.onPrevious,
    required this.onNext,
    required this.onPreviousChapter,
    required this.onNextChapter,
  });
  final double progress;
  final Color foreground;
  final bool pages;
  final bool rightToLeft;
  final VoidCallback onPrevious, onNext, onPreviousChapter, onNextChapter;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 62,
    child: Row(
      children: [
        IconButton(
          tooltip: 'Previous chapter',
          color: foreground,
          onPressed: onPreviousChapter,
          icon: const Icon(Icons.first_page),
        ),
        IconButton(
          tooltip: pages ? 'Previous page' : 'Previous screen',
          color: foreground,
          onPressed: onPrevious,
          icon: Icon(rightToLeft ? Icons.chevron_right : Icons.chevron_left),
        ),
        Expanded(
          child: Semantics(
            label: '${(progress * 100).round()} percent read',
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              backgroundColor: foreground.withValues(alpha: .16),
              color: accent,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '${(progress * 100).round()}%',
            style: TextStyle(color: foreground),
          ),
        ),
        IconButton(
          tooltip: pages ? 'Next page' : 'Next screen',
          color: foreground,
          onPressed: onNext,
          icon: Icon(rightToLeft ? Icons.chevron_left : Icons.chevron_right),
        ),
        IconButton(
          tooltip: 'Next chapter',
          color: foreground,
          onPressed: onNextChapter,
          icon: const Icon(Icons.last_page),
        ),
      ],
    ),
  );
}

/// Shared settings content hosted in a phone sheet or tablet panel.
class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({required this.controller});
  final ReaderController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final settings = controller.settings;
      return SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Reading settings',
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontFamily: 'Lora'),
                  ),
                ),
                IconButton(
                  tooltip: 'Close settings',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Reading mode'),
            const SizedBox(height: 8),
            SegmentedButton<ReadingMode>(
              segments: const [
                ButtonSegment(value: ReadingMode.pages, label: Text('Pages')),
                ButtonSegment(
                  value: ReadingMode.pageFlip,
                  label: Text('Page flip'),
                ),
                ButtonSegment(value: ReadingMode.scroll, label: Text('Scroll')),
              ],
              selected: {settings.mode},
              onSelectionChanged: (value) =>
                  controller.configure(mode: value.first),
            ),
            const SizedBox(height: 22),
            Text('Text size · ${settings.fontSize}%'),
            Slider(
              value: settings.fontSize.toDouble(),
              min: 80,
              max: 180,
              divisions: 10,
              onChanged: (value) =>
                  controller.configure(fontSize: value.round()),
            ),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Serif')),
                ButtonSegment(value: false, label: Text('Sans serif')),
              ],
              selected: {settings.serif},
              onSelectionChanged: (value) =>
                  controller.configure(serif: value.first),
            ),
            const SizedBox(height: 22),
            const Text('Theme'),
            const SizedBox(height: 8),
            SegmentedButton<ReadingTheme>(
              segments: const [
                ButtonSegment(value: ReadingTheme.paper, label: Text('Paper')),
                ButtonSegment(value: ReadingTheme.sepia, label: Text('Sepia')),
                ButtonSegment(value: ReadingTheme.dark, label: Text('Dark')),
              ],
              selected: {settings.theme},
              onSelectionChanged: (value) =>
                  controller.configure(theme: value.first),
            ),
          ],
        ),
      );
    },
  );
}

/// Recoverable reader failure state that always offers a path to the library.
class _ReaderError extends StatelessWidget {
  const _ReaderError({required this.message, required this.onBack});
  final String message;
  final VoidCallback onBack;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48),
          const SizedBox(height: 16),
          const Text(
            'This book could not be opened.',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          FilledButton(onPressed: onBack, child: const Text('Back to library')),
        ],
      ),
    ),
  );
}
