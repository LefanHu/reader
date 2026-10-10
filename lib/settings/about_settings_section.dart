import 'package:flutter/material.dart';

import 'package:package_info_plus/package_info_plus.dart';

/// Displays lazily cached metadata and shell-owned preference reset.
class AboutSettingsSection extends StatelessWidget {
  /// Renders the existing section without owning requests or action locking.
  const AboutSettingsSection({
    super.key,
    required this.busy,
    required this.onResetPreferences,
    required this.packageInfo,
  });

  /// Metadata lookup lazily initiated by the settings shell.
  final Future<PackageInfo>? packageInfo;

  /// Whether destructive actions are locked.
  final bool busy;

  /// Runs the shell-owned preference reset confirmation.
  final VoidCallback onResetPreferences;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('Reader', style: TextStyle(fontSize: 24)),
      FutureBuilder<PackageInfo>(
        future: packageInfo,
        builder: (context, snapshot) => Text(
          snapshot.hasData
              ? 'Version ${snapshot.data!.version} (${snapshot.data!.buildNumber})'
              : snapshot.hasError
              ? 'Version unavailable'
              : 'Loading version…',
        ),
      ),
      const SizedBox(height: 16),
      OutlinedButton(
        onPressed: () => showLicensePage(
          context: context,
          applicationName: 'Reader',
          applicationVersion: null,
        ),
        child: const Text('Open-source licenses'),
      ),
      const SizedBox(height: 24),
      OutlinedButton(
        onPressed: busy ? null : onResetPreferences,
        child: const Text('Reset preferences'),
      ),
    ],
  );
}
