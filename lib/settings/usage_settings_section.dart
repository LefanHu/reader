import 'package:flutter/material.dart';

import '../app/reader_controller.dart';
import '../account/account_usage_exception.dart';

/// Displays live allowance state; refresh remains an explicit user action.
class UsageSettingsSection extends StatelessWidget {
  /// Renders the existing section without owning requests or action locking.
  const UsageSettingsSection({super.key, required this.controller});

  /// Live shared allowance and account state.
  final ReaderController controller;

  @override
  Widget build(BuildContext context) {
    final usage = controller.accountUsage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Usage & allowance', style: TextStyle(fontSize: 22)),
        const SizedBox(height: 12),
        if (controller.cloudEmail == null)
          const Text('Sign in to view your allowance.')
        else if (controller.accountApi?.configured != true)
          const Text('Usage service is not configured in this build.')
        else if (controller.usageLoading)
          const Center(child: CircularProgressIndicator())
        else if (controller.usageError != null) ...[
          Text(switch (controller.usageFailure) {
            AccountUsageFailureKind.offline => 'You are offline',
            AccountUsageFailureKind.attestation => 'App verification required',
            _ => 'Usage service unavailable',
          }, style: Theme.of(context).textTheme.titleMedium),
          Text(controller.usageError!),
        ] else if (usage != null) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Narration characters remaining'),
            subtitle: Text(
              '${usage.narrationRemaining} of ${usage.narrationMonthlyLimit}\nResets ${usage.narrationResetAt.toUtc().toIso8601String().split('T').first} UTC',
            ),
          ),
          Text(
            usage.narrationEnabled
                ? 'Narration is available'
                : 'Narration is currently disabled',
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Illustration credits'),
            subtitle: Text(
              usage.illustrationCreditsRemaining == null
                  ? 'Not activated'
                  : '${usage.illustrationCreditsRemaining} remaining · ${usage.illustrationCreditsReserved ?? 0} reserved',
            ),
          ),
          Text(
            usage.illustrationsEnabled
                ? 'Illustrations are available'
                : 'Illustrations are currently disabled',
          ),
          const SizedBox(height: 12),
          Text('Updated ${usage.asOf.toLocal()}'),
        ],
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed:
              controller.usageLoading ||
                  controller.cloudEmail == null ||
                  controller.accountApi?.configured != true
              ? null
              : controller.refreshAccountUsage,
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh allowance'),
        ),
      ],
    );
  }
}
