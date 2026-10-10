import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/app/edge_back_gesture.dart';

Future<GlobalKey<NavigatorState>> _mount(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.iOS,
  TextDirection direction = TextDirection.ltr,
  Widget? child,
}) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: ThemeData(platform: platform),
      home: const Scaffold(body: Text('Root')),
    ),
  );
  navigator.currentState!.push(
    MaterialPageRoute<void>(
      builder: (context) => PopScope(
        canPop: false,
        child: Directionality(
          textDirection: direction,
          child: EdgeBackGesture(
            onBack: () => Navigator.pop(context),
            child: Scaffold(body: child ?? const Text('Detail')),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return navigator;
}

Future<void> _swipe(
  WidgetTester tester,
  Offset start,
  double delta, {
  bool cancel = false,
}) async {
  final gesture = await tester.startGesture(start);
  var ended = false;
  try {
    await gesture.moveBy(Offset(delta / 2, 0));
    await gesture.moveBy(Offset(delta / 2, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(EdgeBackGesture), findsOneWidget);
    if (cancel) {
      await gesture.cancel();
    } else {
      await gesture.up();
    }
    ended = true;
    await tester.pumpAndSettle();
  } finally {
    if (!ended) await gesture.cancel();
  }
}

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    for (final direction in TextDirection.values) {
      for (final x in [1.0, 19.0]) {
        for (final delta in [64.0, 100.0]) {
          testWidgets(
            '$platform $direction edge $x moves $delta Back only on release',
            (tester) async {
              await _mount(tester, platform: platform, direction: direction);
              await _swipe(tester, Offset(x, 300), delta);
              expect(find.text('Root'), findsOneWidget);
              expect(find.byType(EdgeBackGesture), findsNothing);
            },
          );
        }
      }
      for (final input in [
        (20.0, 100.0),
        (24.0, 100.0),
        (400.0, -399.0),
        (1.0, 63.0),
        (1.0, 0.0),
        (1.0, -100.0),
        (799.0, -100.0),
      ]) {
        testWidgets('$platform $direction rejects swipe $input', (
          tester,
        ) async {
          await _mount(tester, platform: platform, direction: direction);
          await _swipe(tester, Offset(input.$1, 300), input.$2);
          expect(find.byType(EdgeBackGesture), findsOneWidget);
        });
      }
    }
  }

  testWidgets(
    'accepted edge cancellation and returning below threshold retain route',
    (tester) async {
      await _mount(tester);
      await _swipe(tester, const Offset(1, 300), 100, cancel: true);
      final gesture = await tester.startGesture(const Offset(1, 300));
      var ended = false;
      try {
        await gesture.moveBy(const Offset(100, 0));
        await gesture.moveBy(const Offset(-50, 0));
        await gesture.up();
        ended = true;
        await tester.pumpAndSettle();
        expect(find.byType(EdgeBackGesture), findsOneWidget);
      } finally {
        if (!ended) await gesture.cancel();
      }
    },
  );

  testWidgets('edge tap activates child without navigating', (tester) async {
    var activated = false;
    await _mount(
      tester,
      child: StatefulBuilder(
        builder: (context, setState) {
          return Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => activated = true),
              child: Text(activated ? 'Activated' : 'Tap target'),
            ),
          );
        },
      ),
    );
    await tester.tapAt(Offset(1, tester.getCenter(find.byType(TextButton)).dy));
    await tester.pumpAndSettle();
    expect(find.text('Activated'), findsOneWidget);
    expect(find.byType(EdgeBackGesture), findsOneWidget);
  });

  testWidgets('edge vertical drag scrolls child without navigating', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await _mount(
      tester,
      child: ListView(
        controller: scroll,
        children: [
          for (var i = 0; i < 50; i++)
            SizedBox(height: 80, child: Text('Row $i')),
        ],
      ),
    );
    await tester.dragFrom(const Offset(1, 400), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(find.byType(EdgeBackGesture), findsOneWidget);
  });

  testWidgets('second pointer cannot complete first pointer Back', (
    tester,
  ) async {
    await _mount(tester);
    final first = await tester.startGesture(const Offset(1, 300), pointer: 1);
    final second = await tester.startGesture(const Offset(1, 400), pointer: 2);
    var secondEnded = false;
    try {
      await second.moveBy(const Offset(100, 0));
      await second.up();
      secondEnded = true;
      await tester.pumpAndSettle();
      expect(find.byType(EdgeBackGesture), findsOneWidget);
    } finally {
      await first.cancel();
      if (!secondEnded) await second.cancel();
    }
  });

  for (final beforeDown in [true, false]) {
    testWidgets(
      'covering route ${beforeDown ? 'before' : 'after'} DOWN prevents Back',
      (tester) async {
        final navigator = await _mount(tester);
        TestGesture? gesture;
        var ended = false;
        try {
          if (!beforeDown) {
            gesture = await tester.startGesture(const Offset(1, 300));
            await gesture.moveBy(const Offset(50, 0));
          }
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Cover')),
            ),
          );
          await tester.pumpAndSettle();
          gesture ??= await tester.startGesture(const Offset(1, 300));
          await gesture.moveBy(const Offset(100, 0));
          await gesture.up();
          ended = true;
          await tester.pumpAndSettle();
          expect(find.text('Cover'), findsOneWidget);
          expect(
            find.byType(EdgeBackGesture, skipOffstage: false),
            findsOneWidget,
          );
        } finally {
          if (!ended) await gesture?.cancel();
        }
      },
    );
  }

  testWidgets('pan zoom streams do not perform edge Back', (tester) async {
    await _mount(tester);
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(const Offset(1, 300));
    await gesture.panZoomUpdate(
      const Offset(1, 300),
      pan: const Offset(100, 0),
    );
    await gesture.panZoomEnd();
    await tester.pumpAndSettle();
    expect(find.byType(EdgeBackGesture), findsOneWidget);
  });
}
