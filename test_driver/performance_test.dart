import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

import '../integration_test/support/frame_summary.dart';

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
