import 'package:flutter/material.dart';

/// Independent action target; opening its menu pins a desktop metadata overlay.
class BookActions extends StatelessWidget {
  /// Creates this library component with its book or action inputs.
  const BookActions({
    super.key,
    required this.onDelete,
    this.onLinkWork,
    this.onMenuChanged,
  });

  /// Invoked when the delete menu action is selected.
  final VoidCallback onDelete;

  /// Opens the book catalog sheet; absent without cloud catalog services.
  final VoidCallback? onLinkWork;

  /// Reports menu visibility to retain the stationary metadata overlay.
  final ValueChanged<bool>? onMenuChanged;
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Book actions',
    onOpened: () => onMenuChanged?.call(true),
    onCanceled: () => onMenuChanged?.call(false),
    onSelected: (value) {
      onMenuChanged?.call(false);
      if (value == 'catalog') {
        onLinkWork?.call();
      } else {
        onDelete();
      }
    },
    itemBuilder: (_) => [
      if (onLinkWork != null)
        const PopupMenuItem(value: 'catalog', child: Text('Book catalog…')),
      const PopupMenuItem(value: 'delete', child: Text('Delete')),
    ],
  );
}
