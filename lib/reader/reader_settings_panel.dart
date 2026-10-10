import 'package:flutter/material.dart';

import '../app/reader_controller.dart';
import '../preferences/reading_mode.dart';
import '../preferences/reading_theme.dart';

/// Shared settings content hosted in a phone sheet or tablet panel.
class ReaderSettingsPanel extends StatelessWidget {
  /// Creates reader-specific controls subscribed to the shared controller.
  const ReaderSettingsPanel({super.key, required this.controller});

  /// Shared owner of serialized preference updates.
  final ReaderController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final settings = controller.preferences.settings;
      return SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Reading settings',
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontFamily: 'Lora'),
                  ),
                ),
                IconButton(
                  tooltip: 'Close settings',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Reading mode'),
            const SizedBox(height: 8),
            SegmentedButton<ReadingMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ReadingMode.pages, label: Text('Pages')),
                ButtonSegment(
                  value: ReadingMode.pageFlip,
                  label: Text('Page flip'),
                ),
                ButtonSegment(value: ReadingMode.scroll, label: Text('Scroll')),
              ],
              selected: {settings.mode},
              onSelectionChanged: (value) =>
                  controller.preferences.configure(mode: value.first),
            ),
            const SizedBox(height: 22),
            Text('Text size · ${settings.fontSize}%'),
            Slider(
              value: settings.fontSize.toDouble(),
              min: 80,
              max: 180,
              divisions: 10,
              onChanged: (value) =>
                  controller.preferences.configure(fontSize: value.round()),
            ),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: true, label: Text('Serif')),
                ButtonSegment(value: false, label: Text('Sans serif')),
              ],
              selected: {settings.serif},
              onSelectionChanged: (value) =>
                  controller.preferences.configure(serif: value.first),
            ),
            const SizedBox(height: 22),
            const Text('Theme'),
            const SizedBox(height: 8),
            SegmentedButton<ReadingTheme>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ReadingTheme.paper, label: Text('Paper')),
                ButtonSegment(value: ReadingTheme.sepia, label: Text('Sepia')),
                ButtonSegment(value: ReadingTheme.dark, label: Text('Dark')),
              ],
              selected: {settings.theme},
              onSelectionChanged: (value) =>
                  controller.preferences.configure(theme: value.first),
            ),
          ],
        ),
      );
    },
  );
}
