import 'package:flutter/material.dart';

import '../book_analysis/book_analysis_state.dart';

/// Read-only preprocessing status shown in the illustration sheet.
///
/// Reflects persisted [BookAnalysisState] only; it never starts work, prompts
/// for sign-in, or exposes anything but sanitized status and coverage counts.
class AnalysisProgressBanner extends StatelessWidget {
  /// A null [state] means no preprocessing services or no state yet.
  const AnalysisProgressBanner({super.key, required this.state});

  /// Current state for the open book, if any.
  final BookAnalysisState? state;

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    if (state == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final total = state.requiredChunks;
    final done = state.processedChunks;
    final active =
        state.status == BookAnalysisStatus.extracting ||
        state.status == BookAnalysisStatus.finalizing ||
        state.status == BookAnalysisStatus.queued;
    final String label = switch (state.status) {
      BookAnalysisStatus.complete => 'Book analysis complete',
      BookAnalysisStatus.extracting =>
        total > 0 ? 'Analyzing book: $done of $total parts' : 'Analyzing book',
      BookAnalysisStatus.finalizing => 'Finishing book analysis',
      BookAnalysisStatus.queued => 'Book analysis queued',
      BookAnalysisStatus.waitingConsent =>
        'Waiting for illustration setup before analyzing this book',
      BookAnalysisStatus.waitingAccount => 'Waiting for Google sign-in',
      BookAnalysisStatus.waitingService =>
        'Analysis service unavailable; will retry',
      BookAnalysisStatus.waitingConnection => 'Waiting for a connection',
      BookAnalysisStatus.failed =>
        'Book analysis failed${state.failureCategory == null ? '' : ' (${state.failureCategory})'}',
    };
    final double? value = state.status == BookAnalysisStatus.complete
        ? 1
        : state.status == BookAnalysisStatus.extracting && total > 0
        ? done / total
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Semantics(
        container: true,
        liveRegion: true,
        label: label,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
            if (active || state.status == BookAnalysisStatus.complete) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(value: value),
            ],
          ],
        ),
      ),
    );
  }
}
