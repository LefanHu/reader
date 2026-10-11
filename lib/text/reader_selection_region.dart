import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'dictionary_lookup.dart';

/// Owns only ephemeral selection, native handles, and the book's selection menu.
/// Measured prose remains owned by SectionLayout; selection never writes anchors.
class ReaderSelectionRegion extends StatefulWidget {
  /// Wraps the currently rendered book content in the platform selection system.
  const ReaderSelectionRegion({
    super.key,
    required this.child,
    required this.onSelectionChanged,
    this.onReadFromHere,
  });

  /// Visible committed-page slices or the active section's scroll content.
  final Widget child;

  /// Immediately fences navigation and progress while selected content exists.
  final ValueChanged<bool> onSelectionChanged;

  /// Starts narration from captured source provenance after dismissing selection.
  /// Absent when the reader has no narration service.
  final VoidCallback? onReadFromHere;

  @override
  State<ReaderSelectionRegion> createState() => ReaderSelectionRegionState();
}

/// Lets the viewport clear selection before replacing or disposing borrowed text.
class ReaderSelectionRegionState extends State<ReaderSelectionRegion> {
  final _area = GlobalKey<SelectionAreaState>();
  SelectedContent? _selected;
  bool _clearing = false;
  bool _lookupOpen = false;

  /// Removes handles/menu without notifying a viewport that may be rebuilding.
  void clearSelection() {
    _clearing = true;
    try {
      final region = _area.currentState?.selectableRegion;
      region?.hideToolbar();
      // Source replacement can still have registration updates queued. With no
      // selection there is nothing to clear; do not dispatch into those leaves.
      if (_selected != null) region?.clearSelection();
      _selected = null;
      if (_lookupOpen) {
        _lookupOpen = false;
        unawaited(dismissDictionary());
      }
    } finally {
      _clearing = false;
    }
  }

  void _changed(SelectedContent? content) {
    _selected = content;
    if (!_clearing) {
      widget.onSelectionChanged(content?.plainText.isNotEmpty == true);
    }
  }

  Future<void> _lookUp(
    String selected,
    TextSelectionToolbarAnchors anchors,
    SelectableRegionState region,
  ) async {
    // Capture the word and global anchor before dismissing the Flutter toolbar.
    region.hideToolbar();
    _lookupOpen = true;
    try {
      await lookupDictionary(
        selected,
        Rect.fromLTWH(anchors.primaryAnchor.dx, anchors.primaryAnchor.dy, 1, 1),
      );
    } on Exception catch (error) {
      _lookupOpen = false;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the dictionary: $error')),
      );
    }
  }

  Widget _menu(BuildContext context, SelectableRegionState region) {
    final anchors = region.contextMenuAnchors;
    final selected = _selected?.plainText;
    final platform = Theme.of(context).platform;
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: anchors,
      buttonItems: [
        ...region.contextMenuButtonItems,
        if (selected != null &&
            selected.isNotEmpty &&
            widget.onReadFromHere != null)
          ContextMenuButtonItem(
            label: 'Read from here',
            onPressed: () {
              // Capture the action first: clearing selection clears provenance.
              final read = widget.onReadFromHere!;
              region.hideToolbar();
              read();
              clearSelection();
              widget.onSelectionChanged(false);
            },
          ),
        if (selected != null &&
            selected.isNotEmpty &&
            (platform == TargetPlatform.iOS ||
                platform == TargetPlatform.macOS))
          ContextMenuButtonItem(
            type: ContextMenuButtonType.lookUp,
            label: 'Look Up',
            onPressed: () => unawaited(_lookUp(selected, anchors, region)),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => SelectionArea(
    key: _area,
    onSelectionChanged: _changed,
    contextMenuBuilder: _menu,
    child: widget.child,
  );

  @override
  void dispose() {
    clearSelection();
    super.dispose();
  }
}
