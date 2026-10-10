import 'package:flutter/material.dart';

/// Accessible page/chapter controls and publication-wide progress display.
class ReaderNavigationBar extends StatelessWidget {
  /// Creates navigation controls without owning the viewport navigation.
  const ReaderNavigationBar({
    super.key,
    required this.progress,
    required this.foreground,
    required this.pages,
    required this.rightToLeft,
    required this.onPrevious,
    required this.onNext,
    required this.onPreviousChapter,
    required this.onNextChapter,
  });

  /// Publication-wide reading progress.
  final double progress;

  /// Shared reader ink color.
  final Color foreground;

  /// Whether movement is presented as pages rather than screens.
  final bool pages;

  /// Direction of the currently committed paragraph.
  final bool rightToLeft;

  /// Moves to the previous page or screen.
  final VoidCallback onPrevious;

  /// Moves to the next page or screen.
  final VoidCallback onNext;

  /// Moves to the previous chapter.
  final VoidCallback onPreviousChapter;

  /// Moves to the next chapter.
  final VoidCallback onNextChapter;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 62,
    child: Row(
      children: [
        IconButton(
          tooltip: 'Previous chapter',
          color: foreground,
          onPressed: onPreviousChapter,
          icon: const Icon(Icons.first_page),
        ),
        IconButton(
          tooltip: pages ? 'Previous page' : 'Previous screen',
          color: foreground,
          onPressed: onPrevious,
          icon: Icon(rightToLeft ? Icons.chevron_right : Icons.chevron_left),
        ),
        Expanded(
          child: Semantics(
            label: '${(progress * 100).round()} percent read',
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              backgroundColor: foreground.withValues(alpha: .16),
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '${(progress * 100).round()}%',
            style: TextStyle(color: foreground),
          ),
        ),
        IconButton(
          tooltip: pages ? 'Next page' : 'Next screen',
          color: foreground,
          onPressed: onNext,
          icon: Icon(rightToLeft ? Icons.chevron_left : Icons.chevron_right),
        ),
        IconButton(
          tooltip: 'Next chapter',
          color: foreground,
          onPressed: onNextChapter,
          icon: const Icon(Icons.last_page),
        ),
      ],
    ),
  );
}
