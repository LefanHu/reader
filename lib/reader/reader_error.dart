import 'package:flutter/material.dart';

/// Recoverable reader failure state that always offers a path to the library.
class ReaderError extends StatelessWidget {
  /// Creates the failure presentation with a shell-owned return action.
  const ReaderError({super.key, required this.message, required this.onBack});

  /// Failure details from opening the publication.
  final String message;

  /// Returns to the library through the reader shell.
  final VoidCallback onBack;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48),
          const SizedBox(height: 16),
          const Text(
            'This book could not be opened.',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          FilledButton(onPressed: onBack, child: const Text('Back to library')),
        ],
      ),
    ),
  );
}
