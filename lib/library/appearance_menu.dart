import 'package:flutter/material.dart';

import '../app/reader_controller.dart';
import '../preferences/reading_theme.dart';

/// Library accounts remain separate from per-book upload consent and API rollout.
/// Library entry point to the persisted app-wide palette and dependency notices.
/// Menu radios retain their selected semantics and close after a choice.
class LibraryAppearanceMenu extends StatefulWidget {
  /// Creates this library component with its book or action inputs.
  const LibraryAppearanceMenu({super.key, required this.controller});

  /// Shared application state used for persisted appearance choices.
  final ReaderController controller;
  @override
  State<LibraryAppearanceMenu> createState() => _LibraryAppearanceMenuState();
}

class _LibraryAppearanceMenuState extends State<LibraryAppearanceMenu> {
  final menu = MenuController();
  @override
  Widget build(BuildContext context) => MenuAnchor(
    controller: menu,
    builder: (context, controller, _) => IconButton(
      tooltip: 'Appearance',
      icon: const Icon(Icons.palette_outlined),
      onPressed: () =>
          controller.isOpen ? controller.close() : controller.open(),
    ),
    menuChildren: [
      for (final preset in ReadingTheme.values)
        RadioMenuButton<ReadingTheme>(
          value: preset,
          groupValue: widget.controller.preferences.settings.theme,
          onChanged: (value) {
            if (value != null) {
              widget.controller.preferences.configure(theme: value);
            }
          },
          child: Text(switch (preset) {
            ReadingTheme.paper => 'Paper',
            ReadingTheme.sepia => 'Sepia',
            ReadingTheme.dark => 'Dark',
          }),
        ),
      const Divider(),
      MenuItemButton(
        onPressed: () {
          menu.close();
          showLicensePage(
            context: context,
            applicationName: 'Reader',
            applicationLegalese: 'Text layout uses Flutter with Unicode-aware passage positions.',
          );
        },
        leadingIcon: const Icon(Icons.info_outline),
        child: const Text('Open source licenses'),
      ),
    ],
  );
}
