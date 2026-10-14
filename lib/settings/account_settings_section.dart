import 'package:flutter/material.dart';

import '../app/reader_controller.dart';
import 'account_monogram.dart';
import 'insight_previews.dart';
import 'library_summary.dart';
import 'settings_group.dart';

/// Account identity, local reading totals, history previews and cloud actions.
///
/// Library totals come from the local catalog, so they show signed out and
/// offline. Selecting this section never requests usage from the server.
class AccountSettingsSection extends StatelessWidget {
  /// Renders the existing section without owning requests or action locking.
  const AccountSettingsSection({
    super.key,
    required this.controller,
    required this.busy,
    required this.onSignInOrOut,
    required this.onDeleteAccount,
  });

  /// Live shared account and service state.
  final ReaderController controller;

  /// Whether the shell has a destructive action in progress.
  final bool busy;

  /// Runs the shell-owned sign-in or sign-out action.
  final VoidCallback onSignInOrOut;

  /// Runs the shell-owned deletion confirmation and transaction.
  final VoidCallback onDeleteAccount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final email = controller.cloudEmail;
    final locked = busy || controller.cloudAccountBusy;
    final deletable = controller.accountApi?.configured == true;
    final summary = LibrarySummary.of(controller.catalog.books);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            AccountMonogram(email: email),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    email ?? 'You are signed out',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    email == null
                        ? 'Importing and reading never require an account.'
                        : 'Signed in with Google',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (email == null) ...[
          const Text(
            'Sign in to narrate books, illustrate scenes and analyze characters and places.',
          ),
          const SizedBox(height: 16),
        ],
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton(
            onPressed: locked ? null : onSignInOrOut,
            child: Text(email == null ? 'Sign in with Google' : 'Sign out'),
          ),
        ),
        const SizedBox(height: 40),
        SettingsGroup(
          title: 'Your library',
          caption: summary.books == 0
              ? 'Import a book to start counting.'
              : 'Counted from reading progress on this device.',
          children: [LibrarySummaryFigures(summary: summary)],
        ),
        const SettingsGroup(
          title: 'Insights',
          caption: 'Previews. These fill in once Reader records the history behind them.',
          children: [InsightPreviews()],
        ),
        if (email != null)
          SettingsGroup(
            title: 'Cloud data',
            caption: 'Deleting removes your cloud narration, illustrations and analysis. Books and reading positions on this device stay.',
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: scheme.error,
                    side: BorderSide(color: scheme.error.withValues(alpha: .5)),
                  ),
                  onPressed: locked || !deletable ? null : onDeleteAccount,
                  child: const Text('Delete cloud account'),
                ),
              ),
              if (!deletable) ...[
                const SizedBox(height: 8),
                Text(
                  'Cloud account deletion requires a configured service connection.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
      ],
    );
  }
}
