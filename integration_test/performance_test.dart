import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'scenarios/performance.dart';

/// Opt-in native profiler; debug correctness runs stay in reader_test.dart.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Follow engine/app frame requests, not synthetic pump frames or pointer fades.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;
  group('Performance', () => registerPerformanceTests(binding));
}
