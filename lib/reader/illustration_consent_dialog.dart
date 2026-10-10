import 'package:flutter/material.dart';

import '../illustrations/illustration_setup.dart';

/// Consent and art-direction confirmation before any prose leaves the device.
class IllustrationConsentDialog extends StatefulWidget {
  /// Creates a consent presentation returning the selected art direction.
  const IllustrationConsentDialog({super.key, required this.setup});

  /// Registration estimate and suggested art directions.
  final IllustrationSetup setup;

  @override
  State<IllustrationConsentDialog> createState() =>
      _IllustrationConsentDialogState();
}

class _IllustrationConsentDialogState extends State<IllustrationConsentDialog> {
  late String style = widget.setup.suggestedStyle;

  @override
  Widget build(BuildContext context) {
    final styles = <String>{
      widget.setup.suggestedStyle,
      ...widget.setup.alternativeStyles,
    }.toList();
    return AlertDialog(
      title: const Text('Illustrate this book?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Reader sends only the current and next chapter’s normalized '
              'text to the private generation service. The source book is never '
              'uploaded or changed, and art stays locked until you pass the '
              'scene it depicts.',
            ),
            const SizedBox(height: 16),
            Text(
              'Estimated maximum: ${widget.setup.estimatedCredits} credits '
              'for this book. Credits are charged only for completed images.',
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: style,
              decoration: const InputDecoration(labelText: 'Art direction'),
              items: styles
                  .map(
                    (item) => DropdownMenuItem(value: item, child: Text(item)),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => style = value);
              },
            ),
            const SizedBox(height: 12),
            const Text(
              'Google sign-in is used to protect generation credits. '
              'Reading remains available offline and without an account.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, style),
          child: const Text('Enable illustrations'),
        ),
      ],
    );
  }
}
