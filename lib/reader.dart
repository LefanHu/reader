import 'package:flutter/material.dart';
import 'package:flureadium/flureadium.dart';
import 'package:url_launcher/url_launcher.dart';

import 'controller.dart';
import 'models.dart';
import 'theme.dart';

typedef ReaderViewBuilder = Widget Function({
  required Publication publication,
  required Locator? initialLocator,
  required ValueChanged<Offset> onTap,
  required ValueChanged<String> onExternalLink,
  required ValueChanged<Locator> onLocatorChanged,
  required VoidCallback onReady,
});

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.book,
    required this.controller,
    this.readerBuilder,
  });
  final CatalogBook book;
  final ReaderController controller;
  final ReaderViewBuilder? readerBuilder;
  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  late final Future<Publication> publication;
  ReaderSettings? appliedSettings;
  bool controls = true;
  bool closed = false;
  String? chapterTitle;

  @override
  void initState() {
    super.initState();
    publication = _open();
    widget.controller.addListener(_settingsChanged);
  }

  Future<Publication> _open() async {
    widget.controller.engine.setDefaults(
      _preferences(widget.controller.settings),
    );
    appliedSettings = widget.controller.settings;
    return widget.controller.engine.open(widget.book.path);
  }

  void _settingsChanged() {
    final current = widget.controller.settings;
    if (current == appliedSettings) return;
    appliedSettings = current;
    widget.controller.engine.setPreferences(_preferences(current));
    if (mounted) setState(() {});
  }

  EPUBPreferences _preferences(ReaderSettings settings) {
    final colors = switch (settings.theme) {
      ReadingTheme.paper => (const Color(0xFFF7F4ED), const Color(0xFF292E29)),
      ReadingTheme.sepia => (const Color(0xFFF0E1C2), const Color(0xFF453A2E)),
      ReadingTheme.dark => (const Color(0xFF171A18), const Color(0xFFE8E3D8)),
    };
    return EPUBPreferences(
      fontFamily: settings.serif ? 'serif' : 'sans-serif',
      fontSize: settings.fontSize,
      fontWeight: 1,
      verticalScroll: settings.mode == ReadingMode.scroll,
      backgroundColor: colors.$1,
      textColor: colors.$2,
      pageMargins: 1,
    );
  }

  Color get _background => switch (widget.controller.settings.theme) {
    ReadingTheme.paper => const Color(0xFFF7F4ED),
    ReadingTheme.sepia => const Color(0xFFF0E1C2),
    ReadingTheme.dark => const Color(0xFF171A18),
  };

  Color get _foreground => widget.controller.settings.theme == ReadingTheme.dark
      ? const Color(0xFFE8E3D8)
      : ink;

  Future<void> _externalLink(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null || !{'http', 'https'}.contains(uri.scheme) || !mounted) {
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Open external link?'),
        content: Text('This book wants to open ${uri.host} in Safari.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open Safari'),
          ),
        ],
      ),
    );
    if (approved == true) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _showToc(Publication pub) async {
    final items = <({Link link, int depth})>[];
    void add(List<Link> links, int depth) {
      for (final link in links) {
        items.add((link: link, depth: depth));
        add(link.children, depth + 1);
      }
    }

    add(pub.tableOfContents, 0);
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This book has no table of contents.')),
      );
      return;
    }
    final choice = await showModalBottomSheet<Link>(
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
                          title: Text(item.link.title ?? 'Untitled section'),
                          onTap: () => Navigator.pop(context, item.link),
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
    if (choice != null) await widget.controller.engine.goByLink(choice, pub);
  }

  Future<void> _showSettings() async {
    final panel = _SettingsPanel(controller: widget.controller);
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

  Future<void> _close() async {
    if (closed) return;
    closed = true;
    await widget.controller.flush();
    await widget.controller.engine.close();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_settingsChanged);
    widget.controller.flush();
    if (!closed) widget.controller.engine.close();
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
          child: FutureBuilder<Publication>(
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
                  if (controls)
                    _Toolbar(
                      title: chapterTitle ?? widget.book.title,
                      foreground: _foreground,
                      onBack: _close,
                      onToc: () => _showToc(pub),
                      onSettings: _showSettings,
                      onHide: () => setState(() => controls = false),
                    )
                  else
                    Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        tooltip: 'Show reading controls',
                        color: _foreground,
                        onPressed: () => setState(() => controls = true),
                        icon: const Icon(Icons.visibility_outlined),
                      ),
                    ),
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 680),
                        child: _readerView(pub),
                      ),
                    ),
                  ),
                  if (controls)
                    _NavigationBar(
                      progress:
                          widget.controller.books
                              .where((book) => book.hash == widget.book.hash)
                              .firstOrNull
                              ?.progress ??
                          widget.book.progress,
                      foreground: _foreground,
                      pages:
                          widget.controller.settings.mode == ReadingMode.pages,
                      onPrevious:
                          pub.metadata.effectiveReadingProgression ==
                              ReadingProgression.rtl
                          ? widget.controller.engine.goRight
                          : widget.controller.engine.goLeft,
                      onNext:
                          pub.metadata.effectiveReadingProgression ==
                              ReadingProgression.rtl
                          ? widget.controller.engine.goLeft
                          : widget.controller.engine.goRight,
                      onPreviousChapter:
                          widget.controller.engine.previousChapter,
                      onNextChapter: widget.controller.engine.nextChapter,
                    ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _readerView(Publication pub) {
    final initial = Locator.fromJson(
      widget.book.lastLocator == null
          ? null
          : Map<String, dynamic>.of(widget.book.lastLocator!),
    );
    void locatorChanged(Locator locator) {
      widget.controller.saveLocator(widget.book, locator);
      if (chapterTitle != locator.title && mounted) {
        setState(() => chapterTitle = locator.title);
      }
    }

    void ready() => widget.controller.engine.setPreferences(
      _preferences(widget.controller.settings),
    );
    final custom = widget.readerBuilder;
    if (custom != null) {
      return custom(
        publication: pub,
        initialLocator: initial,
        onTap: (_) => setState(() => controls = !controls),
        onExternalLink: _externalLink,
        onLocatorChanged: locatorChanged,
        onReady: ready,
      );
    }
    return ReadiumReaderWidget(
      publication: pub,
      initialLocator: initial,
      onTap: (_) => setState(() => controls = !controls),
      onExternalLinkActivated: _externalLink,
      onLocatorChanged: locatorChanged,
      onReady: ready,
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.title,
    required this.foreground,
    required this.onBack,
    required this.onToc,
    required this.onSettings,
    required this.onHide,
  });
  final String title;
  final Color foreground;
  final VoidCallback onBack, onToc, onSettings, onHide;
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

class _NavigationBar extends StatelessWidget {
  const _NavigationBar({
    required this.progress,
    required this.foreground,
    required this.pages,
    required this.onPrevious,
    required this.onNext,
    required this.onPreviousChapter,
    required this.onNextChapter,
  });
  final double progress;
  final Color foreground;
  final bool pages;
  final Future<void> Function() onPrevious,
      onNext,
      onPreviousChapter,
      onNextChapter;
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
          icon: const Icon(Icons.chevron_left),
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
          icon: const Icon(Icons.chevron_right),
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
