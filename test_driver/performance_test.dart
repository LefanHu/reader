import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// Host-side artifact writer. Labels never become arbitrary paths, and previous
/// captures are never silently overwritten. Failed runs remain marked incomplete.
Future<void> main() async {
  final label =
      Platform.environment['PROFILE_LABEL'] ??
      'run-${DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '')}';
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,95}$').hasMatch(label)) {
    throw ArgumentError(
      'PROFILE_LABEL must be 1–96 letters, digits, underscores or hyphens.',
    );
  }
  final directory = Directory('build/performance/$label');
  if (await directory.exists()) {
    throw StateError(
      'Capture already exists: ${directory.path}. Choose a new PROFILE_LABEL.',
    );
  }
  await integrationDriver(
    // The request timeout is also sent to the remote driver extension.
    timeout: const Duration(minutes: 3),
    writeResponseOnFailure: true,
    responseDataCallback: (data) async {
      if (data == null) {
        throw StateError('The profiler returned no capture data.');
      }
      await writeResponseData(
        data,
        testOutputFilename: 'raw',
        destinationDirectory: directory.path,
      );
      final metadata = (data['metadata'] as Map).cast<String, dynamic>();
      final refreshRate = (metadata['refresh_rate_hz'] as num).toDouble();
      // Unknown display rates use an explicit 60 Hz reference, not a claim about
      // the device. Total span includes scheduling latency; budget UI/raster apart.
      final budgetUs = 1000000 / (refreshRate > 0 ? refreshRate : 60);
      final summaries = <String, Object?>{};
      for (final entry in (data['phases'] as Map).entries) {
        final phase = (entry.value as Map).cast<String, dynamic>();
        summaries[entry.key as String] = summarizeFrames(
          (phase['frames'] as List).cast<Map<String, dynamic>>(),
          budgetUs: budgetUs,
        );
        await writeResponseData(
          (phase['timeline'] as Map).cast<String, dynamic>(),
          testOutputFilename: '${entry.key}_timeline',
          destinationDirectory: directory.path,
        );
      }
      final summary = {
        'schema_version': data['schema_version'],
        'complete': data['complete'] == true,
        'recorded_at_utc': DateTime.now().toUtc().toIso8601String(),
        'metadata': metadata,
        'frame_budget_ms': budgetUs / 1000,
        'budget_uses_fallback': refreshRate <= 0,
        'phases': summaries,
      };
      await writeResponseData(
        summary,
        testOutputFilename: 'summary',
        destinationDirectory: directory.path,
      );
      stdout.writeln('Performance artifacts: ${directory.path}');
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(summary));
    },
  ).timeout(const Duration(minutes: 3));
}

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
