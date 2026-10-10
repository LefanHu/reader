import 'package:flutter/material.dart';

/// Top reader controls for leaving, navigating, configuring, and hiding chrome.
class ReaderToolbar extends StatelessWidget {
  /// Creates toolbar controls using callbacks owned by the reader shell.
  const ReaderToolbar({
    super.key,
    required this.title,
    required this.foreground,
    required this.illustrationCount,
    required this.onBack,
    required this.onToc,
    required this.onIllustrations,
    required this.onListen,
    required this.onSettings,
    required this.onHide,
  });

  /// Current chapter title, falling back to the book title in the shell.
  final String title;

  /// Shared reader ink color.
  final Color foreground;

  /// Number of unlocked scenes shown by the illustration badge.
  final int illustrationCount;

  /// Returns to the library through the shell's flush action.
  final VoidCallback onBack;

  /// Opens the publication contents presentation.
  final VoidCallback onToc;

  /// Opens illustration consent or the unlocked gallery.
  final VoidCallback onIllustrations;

  /// Opens narration controls.
  final VoidCallback onListen;

  /// Opens reader-specific appearance controls.
  final VoidCallback onSettings;

  /// Hides chrome without reflowing the viewport.
  final VoidCallback onHide;
  @override
  Widget build(BuildContext context) => IconTheme(
    data: IconThemeData(color: foreground),
    child: SizedBox(
      height: 60,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          alignment: Alignment.center,
          children: [
            // Balance the wider four-button group on both sides. The title stays
            // centered on the viewport and truncates before reaching buttons.
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: (constraints.maxWidth / 2).clamp(0.0, 192.0),
              ),
              child: SizedBox(
                width: double.infinity,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: foreground,
                    fontFamily: 'Lora',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Row(
              children: [
                IconButton(
                  tooltip: 'Back to library',
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back),
                ),
                IconButton(
                  tooltip: 'Listen',
                  onPressed: onListen,
                  icon: const Icon(Icons.headphones_outlined),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Choose chapter',
                  onPressed: onToc,
                  icon: const Icon(Icons.list_alt),
                ),
                Badge(
                  isLabelVisible: illustrationCount > 0,
                  label: Text('$illustrationCount'),
                  child: IconButton(
                    tooltip: 'AI illustrations',
                    onPressed: onIllustrations,
                    icon: const Icon(Icons.auto_awesome_outlined),
                  ),
                ),
                IconButton(
                  tooltip: 'Reading settings',
                  onPressed: onSettings,
                  icon: const Icon(Icons.text_fields),
                ),
                IconButton(
                  tooltip: 'Hide reading controls',
                  onPressed: onHide,
                  icon: const Icon(Icons.visibility_off_outlined),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
