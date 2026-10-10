import 'package:flutter/material.dart';

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
      FutureBuilder<int>(
        future: cacheSize,
        builder: (context, snapshot) => ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Downloaded narration'),
          subtitle: Text(
            snapshot.hasError
                ? 'Cache size unavailable'
                : snapshot.hasData
                ? '${(snapshot.data! / (1024 * 1024)).toStringAsFixed(1)} MiB'
                : 'Calculating…',
          ),
        ),
      ),
      OutlinedButton(
        onPressed: busy ? null : onClearCache,
        child: const Text('Clear narration cache'),
      ),
      const SizedBox(height: 24),
      const Text('Cloud processing', style: TextStyle(fontSize: 20)),
      const SizedBox(height: 8),
      const Text(
        'Narration requires consent for each book before prose is sent to OpenAI. AI-generated speech may contain mistakes. Cloud audio is private and retained for 30 days; temporary prose is removed after generation, with abandoned input cleaned up after 24 hours. Cached replay is free and works offline. Local audio uses a 250 MiB cache.',
      ),
    ],
  );
}
