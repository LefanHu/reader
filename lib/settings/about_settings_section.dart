import 'package:flutter/material.dart';

import 'package:package_info_plus/package_info_plus.dart';

import 'settings_group.dart';

/// Displays lazily cached metadata and shell-owned preference reset.
class AboutSettingsSection extends StatelessWidget {
  /// Renders the existing section without owning requests or action locking.
  const AboutSettingsSection({
    super.key,
    required this.busy,
    required this.onResetPreferences,
    required this.packageInfo,
    required this.onPreviewTextEffects,
  });

  /// Metadata lookup lazily initiated by the settings shell.
  final Future<PackageInfo>? packageInfo;

  /// Whether destructive actions are locked.
  final bool busy;

  /// Runs the shell-owned preference reset confirmation.
  final VoidCallback onResetPreferences;

  /// Opens the development preview of reading text effects.
  final VoidCallback onPreviewTextEffects;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Reader',
          style: TextStyle(
            fontFamily: 'Lora',
            fontSize: 32,
            height: 1.2,
            fontWeight: FontWeight.w500,
          ),
        ),
        FutureBuilder<PackageInfo>(
          future: packageInfo,
          builder: (context, snapshot) => Text(
            snapshot.hasData
                ? 'Version ${snapshot.data!.version} (${snapshot.data!.buildNumber})'
                : snapshot.hasError
                ? 'Version unavailable'
                : 'Loading version…',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 32),
        SettingsGroup(
          title: 'More',
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton(
                  onPressed: () => showLicensePage(
                    context: context,
                    applicationName: 'Reader',
                    applicationVersion: null,
                  ),
                  child: const Text('Open-source licenses'),
                ),
                OutlinedButton(
                  onPressed: onPreviewTextEffects,
                  child: const Text('Preview text effects'),
                ),
              ],
            ),
          ],
        ),
        SettingsGroup(
          title: 'Reset',
          caption:
              'Restores device preferences. Books, account and caches stay.',
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton(
                onPressed: busy ? null : onResetPreferences,
                child: const Text('Reset preferences'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
