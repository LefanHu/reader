import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'selectable_text_slice.dart';

/// Aggregates committed text slices with their normalized paragraph boundaries.
/// Place this inside any Scrollable: Flutter installs its own selection container
/// there, which otherwise hides individual block identities from the delegate.
class ReaderSelectionContent extends StatefulWidget {
  /// [child] contains only book slices, not controls or preview textures.
  const ReaderSelectionContent({
    super.key,
    required this.child,
    this.onSelectedBlock,
  });

  /// The visible page or active section's block column.
  final Widget child;

  /// Reports the first selected source block in reading order, not drag order.
  /// The owner captures this identity without persisting selection as progress.
  final ValueChanged<String?>? onSelectedBlock;

  @override
  State<ReaderSelectionContent> createState() => _ReaderSelectionContentState();
}

class _ReaderSelectionContentState extends State<ReaderSelectionContent> {
  late final _delegate = _BookSelectionDelegate(
    (block) => widget.onSelectedBlock?.call(block),
  );

  @override
  Widget build(BuildContext context) =>
      SelectionContainer(delegate: _delegate, child: widget.child);

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }
}

/// A single paragraph gains no trailing newline; adjacent slices of the same
/// block concatenate unchanged, while selected distinct blocks retain separators.
class _BookSelectionDelegate extends StaticSelectionContainerDelegate {
  _BookSelectionDelegate(this.onSelectedBlock);

  final ValueChanged<String?> onSelectedBlock;

  @override
  SelectedContent? getSelectedContent() {
    StringBuffer? buffer;
    String? previousBlock;
    String? firstBlock;
    for (final selectable in selectables) {
      final content = selectable.getSelectedContent();
      if (content == null || content.plainText.isEmpty) continue;
      final block = (selectable as BookTextSelectable).blockId;
      firstBlock ??= block;
      if (buffer != null && previousBlock != block) buffer.write('\n\n');
      (buffer ??= StringBuffer()).write(content.plainText);
      previousBlock = block;
    }
    onSelectedBlock(firstBlock);
    return buffer == null
        ? null
        : SelectedContent(plainText: buffer.toString());
  }
}
