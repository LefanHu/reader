import 'package:flutter_test/flutter_test.dart';

/// Pumps until [done] while letting real dev-API I/O progress.
///
/// Widget tests run in fake async; real sockets complete only during
/// `runAsync`, and their continuations run on the following pump. Never wait
/// for dev through `pumpAndSettle` alone.
Future<void> pumpUntilDev(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TestFailure('dev API condition not reached');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}
