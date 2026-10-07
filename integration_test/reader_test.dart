import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'scenarios/controls.dart';
import 'scenarios/library.dart';
import 'scenarios/page_flip.dart';
import 'scenarios/reading.dart';
import 'scenarios/narration.dart';

/// Single native runner: feature groups support focused --plain-name runs while
/// each scenario owns a fresh app/catalog through NativeTestApp.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('Library', registerLibraryTests);
  group('Reading', registerReadingTests);
  group('Reader controls', registerControlTests);
  group('Page flip', registerPageFlipTests);
  group('Narration', registerNarrationTests);
}
