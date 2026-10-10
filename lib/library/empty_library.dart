import 'package:flutter/material.dart';

/// Import prompt shown before the first book has been added.
class EmptyLibrary extends StatelessWidget {
  /// Creates this library component with its book or action inputs.
  const EmptyLibrary({super.key, required this.onImport});

  /// Invoked when the import action is selected.
  final VoidCallback onImport;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.menu_book_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 18),
          Text(
            'Your shelf is ready',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontFamily: 'Lora'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Import EPUB or TXT books from Files.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: onImport,
            icon: const Icon(Icons.file_open),
            label: const Text('Import books'),
          ),
        ],
      ),
    ),
  );
}
