import 'package:flutter/material.dart';

import '../app/reader_controller.dart';
import '../account/account_usage.dart';
import '../account/account_usage_exception.dart';
import 'counts.dart';
import 'settings_group.dart';

/// Displays live allowance state; refresh remains an explicit user action.
class UsageSettingsSection extends StatelessWidget {
  /// Renders the existing section without owning requests or action locking.
  const UsageSettingsSection({super.key, required this.controller});

  /// Live shared allowance and account state.
  final ReaderController controller;

  /// Narration balance line, shared with tests so the format has one owner.
  static String narrationBalance(AccountUsage usage) =>
      '${groupedCount(usage.narrationRemaining)} of '
      '${groupedCount(usage.narrationMonthlyLimit)} left';

  /// Reset line; the server resets allowances at midnight UTC.
  static String _narrationReset(AccountUsage usage) =>
      'Resets ${shortDate(usage.narrationResetAt.toUtc())} (UTC)';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final usage = controller.accountUsage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (controller.cloudEmail == null)
          const Text('Sign in to view your allowance.')
        else if (controller.accountApi?.configured != true)
          const Text('Usage service is not configured in this build.')
        else if (controller.usageLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (controller.usageError != null) ...[
          Text(switch (controller.usageFailure) {
            AccountUsageFailureKind.offline => 'You are offline',
            AccountUsageFailureKind.attestation => 'App verification required',
            _ => 'Usage service unavailable',
          }, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(controller.usageError!),
        ] else if (usage != null) ...[
          SettingsGroup(
            title: 'Narration characters remaining',
            caption: usage.narrationEnabled
                ? 'New narration uses one character of allowance per character read. Cached replay is free.'
                : 'Narration is currently disabled.',
            children: [
              _Meter(
                remaining: usage.narrationRemaining,
                total: usage.narrationMonthlyLimit,
              ),
              const SizedBox(height: 8),
              Text(narrationBalance(usage), style: theme.textTheme.bodyLarge),
              Text(_narrationReset(usage), style: muted),
            ],
          ),
          SettingsGroup(
            title: 'Illustration credits',
            caption: usage.illustrationsEnabled
                ? 'Each illustrated scene uses one credit.'
                : 'Illustrations are currently disabled.',
            children: [
              Text(
                usage.illustrationCreditsRemaining == null
                    ? 'Not activated'
                    : '${groupedCount(usage.illustrationCreditsRemaining!)} remaining · '
                          '${groupedCount(usage.illustrationCreditsReserved ?? 0)} reserved',
                style: theme.textTheme.bodyLarge,
              ),
            ],
          ),
          Text('Updated ${_updated(usage.asOf.toLocal())}', style: muted),
        ],
        const SizedBox(height: 16),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            onPressed:
                controller.usageLoading ||
                    controller.cloudEmail == null ||
                    controller.accountApi?.configured != true
                ? null
                : controller.refreshAccountUsage,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh allowance'),
          ),
        ),
      ],
    );
  }

  static String _updated(DateTime local) =>
      '${shortDate(local)}, ${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// Remaining share of an allowance; empty when nothing is left.
class _Meter extends StatelessWidget {
  const _Meter({required this.remaining, required this.total});

  final int remaining;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: total == 0 ? 0 : remaining / total,
          minHeight: 8,
          color: scheme.primary,
          backgroundColor: scheme.outlineVariant,
        ),
      ),
    );
  }
}
