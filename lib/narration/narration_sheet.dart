import 'package:flutter/material.dart';

import '../app/reader_controller.dart';
import '../catalog/catalog_book.dart';
import '../text/document.dart';
import 'narration_consent_dialog.dart';
import 'session.dart';

/// Accessible per-book opt-in before sign-in or any prose upload.
Future<void> showNarrationSheet(
  BuildContext context,
  ReaderController controller,
  CatalogBook book,
) async {
  final session = controller.narration;
  if (session == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Narration is not configured in this build.'),
      ),
    );
    return;
  }
  try {
    await session.attach(book);
    if (!context.mounted) return;
    if (session.manifest.cloudBookId == null) {
      if (!session.api.configured) {
        throw StateError('Narration is not configured in this build.');
      }
      final consent = await showDialog<bool>(
        context: context,
        builder: (_) => const NarrationConsentDialog(),
      );
      if (consent != true) return;
      await controller.consentToNarration(book);
    }
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => NarrationSheet(controller: controller),
    );
  } on Object catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}

/// Renders shared playback and global preferences without owning an audio engine.
class NarrationSheet extends StatelessWidget {
  /// Uses the app-lifetime narration session and controller notification source.
  const NarrationSheet({super.key, required this.controller});

  /// Shared owner of playback, global preferences, and account transactions.
  final ReaderController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final session = controller.narration!;
      if (session.book == null) {
        return const SafeArea(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Text('Narration stopped'),
          ),
        );
      }
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'AI narration',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      PopupMenuButton<bool>(
                        tooltip: 'Cloud account',
                        icon: const Icon(Icons.manage_accounts),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: false, child: Text('Sign out')),
                          PopupMenuItem(
                            value: true,
                            child: Text('Delete cloud account'),
                          ),
                        ],
                        onSelected: (delete) =>
                            _accountAction(context, controller, delete),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      session.error ??
                          switch (session.status) {
                            NarrationStatus.buffering => 'Buffering — cached audio is available offline. Retry when connected.',
                            NarrationStatus.complete => 'Book complete',
                            NarrationStatus.playing => 'Listening',
                            _ => 'Paused',
                          },
                    ),
                  ),
                  Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Back 15 seconds',
                        icon: const Icon(Icons.replay),
                        onPressed: () => session.seek(
                          session.player.position - const Duration(seconds: 15),
                        ),
                      ),
                      IconButton(
                        tooltip: session.ownsPosition(session.book!)
                            ? 'Pause narration'
                            : 'Play narration',
                        icon: Icon(
                          session.ownsPosition(session.book!)
                              ? Icons.pause
                              : Icons.play_arrow,
                        ),
                        onPressed: () => session.ownsPosition(session.book!)
                            ? session.pause()
                            : session.play(),
                      ),
                      IconButton(
                        tooltip: 'Forward 15 seconds',
                        icon: const Icon(Icons.forward),
                        onPressed: () => session.seek(
                          session.player.position + const Duration(seconds: 15),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Stop narration',
                        icon: const Icon(Icons.stop),
                        onPressed: session.stop,
                      ),
                    ],
                  ),
                  DropdownButtonFormField<String>(
                    key: ValueKey(
                      controller.preferences.settings.narrationVoice,
                    ),
                    initialValue:
                        controller.preferences.settings.narrationVoice,
                    decoration: const InputDecoration(
                      labelText: 'Voice · all books',
                    ),
                    items: const [
                      DropdownMenuItem(value: 'marin', child: Text('Marin')),
                      DropdownMenuItem(value: 'cedar', child: Text('Cedar')),
                    ],
                    onChanged: (voice) =>
                        controller.preferences.configure(narrationVoice: voice),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<double>(
                    key: ValueKey(
                      controller.preferences.settings.narrationSpeed,
                    ),
                    initialValue:
                        controller.preferences.settings.narrationSpeed,
                    decoration: const InputDecoration(
                      labelText: 'Speed · all books',
                    ),
                    items: [.75, 1.0, 1.25, 1.5, 1.75, 2.0]
                        .map(
                          (speed) => DropdownMenuItem(
                            value: speed,
                            child: Text('$speed×'),
                          ),
                        )
                        .toList(),
                    onChanged: (speed) =>
                        controller.preferences.configure(narrationSpeed: speed),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    decoration: const InputDecoration(labelText: 'Chapter'),
                    isExpanded: true,
                    items: session.document?.sections
                        .map(
                          (section) => DropdownMenuItem(
                            value: section.id,
                            child: Text(
                              section.title,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (id) async {
                      if (id == null) return;
                      await session.navigate(session.book!);
                      final section = await session.documents.loadSection(
                        session.book!.path,
                        id,
                      );
                      final document = session.document as TextDocument;
                      await controller.savePosition(
                        session.book!,
                        section.start,
                        document.progress(section, section.start),
                        fromNarration: true,
                      );
                      controller.notifyNarrationNavigation();
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(
                    session.remaining == null
                        ? 'Cached replay is free. Connect to refresh allowance.'
                        : '${session.remaining} input characters remaining this UTC month',
                  ),
                  TextButton(
                    onPressed: () async {
                      try {
                        final config = await session.api.configuration();
                        session.remaining = config['remaining'] as int?;
                        controller.notifyNarrationNavigation();
                      } on Object {
                        /* Offline cached listening remains available. */
                      }
                    },
                    child: const Text('Refresh allowance'),
                  ),
                  TextButton(
                    onPressed: session.clear,
                    child: const Text('Clear downloaded audio'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Account deletion requires an explicit user action and preserves local books.
Future<void> _accountAction(
  BuildContext context,
  ReaderController controller,
  bool delete,
) async {
  if (delete) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete cloud account?'),
        content: const Text(
          'This deletes your cloud narration, illustrations and account, and clears downloaded narration. Your local books and reading positions remain.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
  }
  try {
    if (delete) {
      await controller.deleteCloudAccount();
    } else {
      await controller.signOutOfCloud();
    }
    if (context.mounted) Navigator.pop(context);
  } on Object catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}
