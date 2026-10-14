import 'package:flutter/material.dart';

/// A titled run of settings content sharing one heading rhythm across sections.
class SettingsGroup extends StatelessWidget {
  /// Places [children] under [title] with an optional muted [caption].
  const SettingsGroup({
    super.key,
    required this.title,
    this.caption,
    required this.children,
  });

  /// Short heading naming what the controls change.
  final String title;

  /// One sentence on scope or consequence, shown under the heading.
  final String? caption;

  /// Controls or content belonging to this group.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (caption != null) ...[
            const SizedBox(height: 4),
            Text(
              caption!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}
