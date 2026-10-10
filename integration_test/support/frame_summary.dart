/// Summarizes real engine samples without pooling different phases/repetitions.
/// Input durations are microseconds; output times are milliseconds. A frame is
/// over budget only when UI or raster duration strictly exceeds the reference.
/// p95 uses nearest-rank selection; median averages the middle pair for even sets.
Map<String, Object> summarizeFrames(
  List<Map<String, dynamic>> frames, {
  required double budgetUs,
}) {
  if (frames.isEmpty) throw ArgumentError('Cannot summarize an empty phase.');
  if (!budgetUs.isFinite || budgetUs <= 0) {
    throw ArgumentError('Frame budget must be finite and positive.');
  }
  Map<String, double> times(String key) {
    final values =
        frames.map((frame) => (frame[key] as num).toDouble()).toList()..sort();
    if (values.any((value) => !value.isFinite || value < 0)) {
      throw ArgumentError('Frame durations must be finite and non-negative.');
    }
    final middle = values.length ~/ 2;
    return {
      'median_ms':
          (values.length.isOdd
              ? values[middle]
              : (values[middle - 1] + values[middle]) / 2) /
          1000,
      'p95_ms': values[(values.length * .95).ceil() - 1] / 1000,
      'max_ms': values.last / 1000,
    };
  }

  return {
    'frame_count': frames.length,
    'ui': times('build_us'),
    'raster': times('raster_us'),
    'total_span': times('total_us'),
    'ui_over_budget': frames
        .where((frame) => (frame['build_us'] as num) > budgetUs)
        .length,
    'raster_over_budget': frames
        .where((frame) => (frame['raster_us'] as num) > budgetUs)
        .length,
    // Count a frame once even when both threads exceed the reference budget.
    'either_over_budget': frames
        .where(
          (frame) =>
              (frame['build_us'] as num) > budgetUs ||
              (frame['raster_us'] as num) > budgetUs,
        )
        .length,
  };
}
