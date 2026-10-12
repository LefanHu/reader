import 'package:flutter/material.dart';

import '../illustrations/illustration_selection.dart';
import '../illustrations/illustration_setup.dart';

/// Shared per-book art direction and server-owned image source controls.
class IllustrationSelectionForm extends StatelessWidget {
  /// Displays [selection] without changing it until the reader chooses a value.
  const IllustrationSelectionForm({
    super.key,
    required this.setup,
    required this.selection,
    required this.onChanged,
  });

  /// Available sources and book-specific style suggestions.
  final IllustrationSetup setup;

  /// Current draft; unavailable saved sources remain visible, never substituted.
  final IllustrationSelection selection;

  /// Receives an explicit reader choice.
  final ValueChanged<IllustrationSelection> onChanged;

  /// Whether this draft can be confirmed against the current configuration.
  static bool canSubmit(
    IllustrationSetup setup,
    IllustrationSelection selection,
  ) =>
      setup.cloudBookId != null &&
      setup.configuration.enabled &&
      setup.configuration.providers.any(
        (provider) => provider.id == selection.providerId && provider.available,
      );

  /// Uses the saved selection when editing, otherwise the server's OpenAI default.
  static IllustrationSelection initialSelection(IllustrationSetup setup) =>
      IllustrationSelection(
        style: setup.currentProfile?.style ?? setup.suggestedStyle,
        providerId:
            setup.currentProfile?.providerId ??
            setup.configuration.defaultProviderId,
      );

  @override
  Widget build(BuildContext context) {
    final styles = <String>{
      selection.style,
      if (setup.currentProfile != null) setup.currentProfile!.style,
      setup.suggestedStyle,
      ...setup.alternativeStyles,
    }.toList();
    final providers = setup.configuration.providers;
    final knownSelection = providers.any((p) => p.id == selection.providerId);
    final available =
        setup.configuration.enabled &&
        setup.configuration.hasAvailableProvider &&
        setup.cloudBookId != null;
    final selected = providers
        .where((p) => p.id == selection.providerId)
        .firstOrNull;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          key: const ValueKey('illustration-style-selector'),
          initialValue: selection.style,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Art direction'),
          items: styles
              .map(
                (style) => DropdownMenuItem(
                  value: style,
                  child: Text(
                    style,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: (style) {
            if (style != null) {
              onChanged(
                IllustrationSelection(
                  style: style,
                  providerId: selection.providerId,
                ),
              );
            }
          },
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          key: const ValueKey('illustration-provider-selector'),
          initialValue: selection.providerId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Image source'),
          items: [
            if (!knownSelection)
              DropdownMenuItem(
                value: selection.providerId,
                enabled: false,
                child: const Text('Saved source unavailable'),
              ),
            ...providers.map(
              (provider) => DropdownMenuItem(
                value: provider.id,
                enabled: available && provider.available,
                child: Text(
                  '${provider.label}'
                  '${provider.recommended ? ' · Recommended' : ''}'
                  ' · ${provider.costTier}'
                  '${provider.available ? '' : ' · Unavailable'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
          onChanged: available
              ? (providerId) {
                  if (providerId != null) {
                    onChanged(
                      IllustrationSelection(
                        style: selection.style,
                        providerId: providerId,
                      ),
                    );
                  }
                }
              : null,
        ),
        const SizedBox(height: 12),
        if (!available)
          const Text(
            'Illustrations are currently unavailable. No image source '
            'is enabled for this book. You can cancel and keep reading.',
          )
        else if (selected == null || !selected.available)
          const Text(
            'This source is not configured for generation. Choose an '
            'available source to continue; existing artwork is unchanged.',
          )
        else
          Text(
            '${selected.label} receives the selected passage and art '
            'direction. OpenAI still picks scenes from normalized chapter text '
            'and moderates every image. Your source EPUB is never uploaded.',
          ),
        const SizedBox(height: 8),
        const Text(
          'Budget, balanced and premium describe relative provider '
          'costs. Every completed image costs one illustration credit.',
        ),
      ],
    );
  }
}
