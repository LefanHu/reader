import 'package:flutter/material.dart';

/// A preference choice whose actionable tile owns selected semantics.
class SettingsChoiceTile<T> extends StatelessWidget {
  /// Keeps the original radio indicator and optional theme-preview geometry.
  const SettingsChoiceTile({
    super.key,
    required this.value,
    required this.selected,
    required this.title,
    this.subtitle,
    this.preview,
    required this.onChanged,
  });

  /// Value committed when the tile is selected.
  final T value;

  /// Current preference value.
  final T selected;

  /// Label of this choice.
  final Widget title;

  /// Optional explanatory text.
  final Widget? subtitle;

  /// Optional colors shown in the original 42-pixel preview.
  final ColorScheme? preview;

  /// Forwards selection to the shell's serialized preference operation.
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    selected: value == selected,
    leading: Icon(
      value == selected ? Icons.radio_button_checked : Icons.radio_button_off,
    ),
    title: title,
    subtitle: subtitle,
    trailing: preview == null
        ? null
        : Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: preview!.surface,
              border: Border.all(color: preview!.outline),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('Aa', style: TextStyle(color: preview!.onSurface)),
          ),
    onTap: () => onChanged(value),
  );
}
