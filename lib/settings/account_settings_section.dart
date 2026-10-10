import 'package:flutter/material.dart';

import '../app/reader_controller.dart';

/// Account status and shell-owned sign-in and deletion actions.
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
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        controller.cloudEmail ?? 'You are signed out',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 12),
      const Text(
        'Sign in to use cloud features. Importing and reading never require an account.',
      ),
      const SizedBox(height: 20),
      FilledButton(
        onPressed: busy || controller.cloudAccountBusy ? null : onSignInOrOut,
        child: Text(
          controller.cloudEmail == null ? 'Sign in with Google' : 'Sign out',
        ),
      ),
      if (controller.cloudEmail != null) ...[
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed:
              busy ||
                  controller.cloudAccountBusy ||
                  !(controller.narration?.api.configured == true ||
                      controller.illustrations.configured)
              ? null
              : onDeleteAccount,
          child: const Text('Delete cloud account'),
        ),
        if (!(controller.narration?.api.configured == true ||
            controller.illustrations.configured))
          const Text(
            'Cloud account deletion requires a configured service connection.',
          ),
      ],
    ],
  );
}
