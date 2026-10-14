import 'package:flutter/material.dart';

import 'settings_group.dart';

/// Displays the shell-cached narration size and privacy presentation.
class StorageSettingsSection extends StatelessWidget {
  /// Renders the existing section without owning requests or action locking.
  const StorageSettingsSection({
    super.key,
    required this.busy,
    required this.onClearCache,
    required this.cacheSize,
  });

  /// Size lookup initiated and cached by the settings shell.
  final Future<int>? cacheSize;

  /// Whether destructive actions are locked.
  final bool busy;

  /// Runs the shell-owned cache confirmation and deletion.
  final VoidCallback onClearCache;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SettingsGroup(
        title: 'Downloaded narration',
        caption: 'Cached audio replays offline for free. The cache holds up to 250 MiB.',
        children: [
          FutureBuilder<int>(
            future: cacheSize,
            builder: (context, snapshot) => Text(
              snapshot.hasError
                  ? 'Cache size unavailable'
                  : snapshot.hasData
                  ? '${(snapshot.data! / (1024 * 1024)).toStringAsFixed(1)} MiB'
                  : 'Calculating…',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton(
              onPressed: busy ? null : onClearCache,
              child: const Text('Clear narration cache'),
            ),
          ),
        ],
      ),
      const SettingsGroup(
        title: 'Cloud processing',
        children: [
          Text(
            'Cloud narration sends book passages to OpenAI and requires a signed-in account and device verification. AI-generated speech may contain mistakes. Cloud audio is private and retained for 30 days; temporary prose is removed after generation, with abandoned input cleaned up after 24 hours.',
          ),
        ],
      ),
    ],
  );
}
