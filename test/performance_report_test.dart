import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';

import '../integration_test/support/performance_capture.dart';
import '../integration_test/support/frame_summary.dart';

void main() {
  test(
    'CPU compaction preserves function attribution and recursive stack frames',
    () {
      final capture = CpuSamples(
        sampleCount: 2,
        functions: [
          for (var i = 0; i < 5; i++)
            ProfileFunction(resolvedUrl: 'function$i.dart'),
        ],
        samples: [
          CpuSample(stack: [4, 1, 4]),
          CpuSample(stack: [3, 1]),
        ],
      );
      compactCpuSamples(capture);
      expect(capture.functions!.map((function) => function.resolvedUrl), [
        'function1.dart',
        'function3.dart',
        'function4.dart',
      ]);
      expect(
        capture.samples!.map(
          (sample) => [
            for (final index in sample.stack!)
              capture.functions![index].resolvedUrl,
          ],
        ),
        [
          ['function4.dart', 'function1.dart', 'function4.dart'],
          ['function3.dart', 'function1.dart'],
        ],
      );
    },
  );

  test('frame percentiles sort samples and use nearest rank for p95', () {
    final summary = summarizeFrames([
      for (var i = 20; i > 0; i--)
        {'build_us': i * 1000, 'raster_us': i * 2000, 'total_us': i * 3000},
    ], budgetUs: 10000);
    expect(summary['ui'], {'median_ms': 10.5, 'p95_ms': 19.0, 'max_ms': 20.0});
    expect(summary['raster'], {
      'median_ms': 21.0,
      'p95_ms': 38.0,
      'max_ms': 40.0,
    });
    expect(summary['ui_over_budget'], 10);
  });

  test(
    'budget counts exclude equality and latency and do not double count frames',
    () {
      final summary = summarizeFrames([
        {'build_us': 10000, 'raster_us': 10000, 'total_us': 999999},
        {'build_us': 11000, 'raster_us': 0, 'total_us': 999999},
        {'build_us': 0, 'raster_us': 11000, 'total_us': 999999},
        {'build_us': 11000, 'raster_us': 11000, 'total_us': 999999},
      ], budgetUs: 10000);
      expect(summary['ui_over_budget'], 2);
      expect(summary['raster_over_budget'], 2);
      expect(summary['either_over_budget'], 3);
    },
  );

  test(
    'missing or invalid measurements cannot produce a successful summary',
    () {
      expect(() => summarizeFrames([], budgetUs: 10000), throwsArgumentError);
      for (final budget in [0.0, -1.0, double.infinity, double.nan]) {
        expect(
          () => summarizeFrames([
            {'build_us': 1000, 'raster_us': 1000, 'total_us': 1000},
          ], budgetUs: budget),
          throwsArgumentError,
        );
      }
      for (final duration in [-1.0, double.infinity, double.nan]) {
        expect(
          () => summarizeFrames([
            {'build_us': duration, 'raster_us': 1000, 'total_us': 1000},
          ], budgetUs: 10000),
          throwsArgumentError,
        );
      }
    },
  );
}
