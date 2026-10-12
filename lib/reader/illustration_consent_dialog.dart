import 'package:flutter/material.dart';

import '../illustrations/illustration_selection.dart';
import '../illustrations/illustration_setup.dart';
import 'illustration_selection_form.dart';

/// Consent and per-book selection before normalized prose leaves the device.
class IllustrationConsentDialog extends StatelessWidget {
  /// Returns an [IllustrationSelection], or null when cancelled.
  const IllustrationConsentDialog({super.key, required this.setup});

  /// Registration estimate, configuration and suggested art directions.
  final IllustrationSetup setup;

  @override
  Widget build(BuildContext context) =>
      _SelectionDialog(setup: setup, editing: false);
}

/// Edits only this book's preferences, without re-admitting existing work.
class IllustrationSettingsDialog extends StatelessWidget {
  /// Returns a draft to save, or null without changing saved preferences.
  const IllustrationSettingsDialog({super.key, required this.setup});

  /// Authoritative current preferences and server availability.
  final IllustrationSetup setup;

  @override
  Widget build(BuildContext context) =>
      _SelectionDialog(setup: setup, editing: true);
}

class _SelectionDialog extends StatefulWidget {
  const _SelectionDialog({required this.setup, required this.editing});

  final IllustrationSetup setup;
  final bool editing;

  @override
  State<_SelectionDialog> createState() => _SelectionDialogState();
}

class _SelectionDialogState extends State<_SelectionDialog> {
  late IllustrationSelection selection =
      IllustrationSelectionForm.initialSelection(widget.setup);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.editing ? 'Illustration settings' : 'Illustrate this book?',
    ),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.editing
                  ? 'Changes affect future work and explicit regeneration only. '
                        'Ready artwork and already-submitted chapters stay unchanged. '
                        'Explicit regeneration costs one credit per completed image.'
                  : 'Reader sends only the current and next chapter’s normalized '
                        'text so OpenAI can pick illustrated scenes. The source book '
                        'is never uploaded or changed, and art appears beside its '
                        'scene as soon as it is ready.',
            ),
            const SizedBox(height: 16),
            if (!widget.editing) ...[
              Text(
                'Estimated maximum: ${widget.setup.estimatedCredits} credits '
                'for this book. Credits are charged only for completed images.',
              ),
              const SizedBox(height: 16),
            ],
            IllustrationSelectionForm(
              setup: widget.setup,
              selection: selection,
              onChanged: (value) => setState(() => selection = value),
            ),
            if (!widget.editing) ...[
              const SizedBox(height: 12),
              const Text(
                'Google sign-in is used to protect generation credits. '
                'Reading remains available offline and without an account.',
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: IllustrationSelectionForm.canSubmit(widget.setup, selection)
            ? () => Navigator.pop(context, selection)
            : null,
        child: Text(widget.editing ? 'Save' : 'Enable illustrations'),
      ),
    ],
  );
}
