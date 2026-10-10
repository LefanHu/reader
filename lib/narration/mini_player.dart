import 'package:flutter/material.dart';

import '../app/reader_controller.dart';
import 'narration_sheet.dart';
import 'session.dart';

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
