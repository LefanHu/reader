import 'package:flutter/material.dart';

import '../controller.dart';
import '../models.dart';
import '../text/document.dart';
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
        builder: (context) => AlertDialog(
          title: const Text('Listen with AI narration?'),
          content: const SingleChildScrollView(
            child: Text(
              'Selected passages from this book will be sent to OpenAI to generate AI speech. OpenAI may retain API data for up to 30 days for abuse monitoring. Our private cloud audio expires after 30 days; temporary prose is removed when generation finishes, with a 24-hour cleanup policy for abandoned requests.\n\nThe default allowance is 500,000 input characters per UTC month, subject to the service’s daily limit. Generation retries and voice changes use allowance. Cached listening is free and works offline. You can clear downloaded audio or delete the book and its cloud narration.\n\nContinue to sign in with Apple and consent for this book.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Agree and continue'),
            ),
          ],
        ),
      );
      if (consent != true) return;
      await controller.consentToNarration(book);
    }
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _NarrationSheet(controller: controller),
    );
  } on Object catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}

/// App-wide mini-player stays visible when leaving the reader during listening.
class NarrationMiniPlayer extends StatelessWidget {
  /// Uses the shared controller and native handler rather than another player.
  const NarrationMiniPlayer({super.key, required this.controller});

  /// App-lifetime state owns playback across routes.
  final ReaderController controller;
  @override
  Widget build(BuildContext context) {
    final session = controller.narration!;
    if (session.book == null || session.manifest.cloudBookId == null) {
      return const SizedBox.shrink();
    }
    return SafeArea(
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: ListTile(
          leading: const Icon(Icons.headphones),
          title: Text(
            session.book!.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            session.status == NarrationStatus.buffering
                ? 'Buffering'
                : 'AI narration',
          ),
          onTap: () => showNarrationSheet(context, controller, session.book!),
          trailing: IconButton(
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
        ),
      ),
    );
  }
}

class _NarrationSheet extends StatelessWidget {
  const _NarrationSheet({required this.controller});
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
                    initialValue: session.manifest.voice,
                    decoration: const InputDecoration(labelText: 'Voice'),
                    items: const [
                      DropdownMenuItem(value: 'marin', child: Text('Marin')),
                      DropdownMenuItem(value: 'cedar', child: Text('Cedar')),
                    ],
                    onChanged: (voice) => session.configure(voice: voice),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<double>(
                    initialValue: session.manifest.speed,
                    decoration: const InputDecoration(labelText: 'Speed'),
                    items: [.75, 1.0, 1.25, 1.5, 1.75, 2.0]
                        .map(
                          (speed) => DropdownMenuItem(
                            value: speed,
                            child: Text('$speed×'),
                          ),
                        )
                        .toList(),
                    onChanged: (speed) => session.configure(speed: speed),
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
      await controller.deleteIllustrationAccount();
    } else {
      await controller.signOutOfIllustrations();
    }
    if (context.mounted) Navigator.pop(context);
  } on Object catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}
