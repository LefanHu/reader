import 'package:flutter/material.dart';

/// Presents per-book prose-upload consent before any interactive cloud sign-in.
class NarrationConsentDialog extends StatelessWidget {
  /// Returns true only when the reader explicitly agrees to continue.
  const NarrationConsentDialog({super.key});

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Listen with AI narration?'),
    content: const SingleChildScrollView(
      child: Text(
        'Selected passages from this book will be sent to OpenAI to generate AI speech. OpenAI may retain API data for up to 30 days for abuse monitoring. Our private cloud audio expires after 30 days; temporary prose is removed when generation finishes, with a 24-hour cleanup policy for abandoned requests.\n\nThe default allowance is 500,000 input characters per UTC month, subject to the service’s daily limit. Generation retries and voice changes use allowance. Cached listening is free and works offline. You can clear downloaded audio or delete the book and its cloud narration.\n\nContinue to sign in with Google and consent for this book.',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, true),
        child: const Text('Agree and continue'),
      ),
    ],
  );
}
