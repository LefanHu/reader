import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/app/reader_controller.dart';

/// Finishes controller shutdown after the owning widget has been unmounted.
/// Serialized player commands and stream closures can retain the widget test's
/// fake zone, so teardown must keep pumping until its persistence barrier settles.
Future<void> disposeControllerWithFrames(
  WidgetTester tester,
  ReaderController controller,
) async {
  controller.dispose();
  var settled = false;
  Object? failure;
  StackTrace? trace;
  final flush = controller.flush().then<void>(
    (_) => settled = true,
    onError: (Object error, StackTrace stack) {
      failure = error;
      trace = stack;
      settled = true;
    },
  );
  for (var frames = 0; frames < 100 && !settled; frames++) {
    await tester.pump();
  }
  if (!settled) {
    fail('Controller shutdown did not finish while pumping frames.');
  }
  await flush;
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
}

/// Registers unmount-then-dispose teardown for a test-owned [controller].
void addControllerTeardown(WidgetTester tester, ReaderController controller) {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await disposeControllerWithFrames(tester, controller);
  });
}
