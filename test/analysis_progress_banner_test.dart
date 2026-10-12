import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/book_analysis/analysis_protocol.dart';
import 'package:reader/book_analysis/book_analysis_state.dart';
import 'package:reader/reader/analysis_progress_banner.dart';

BookAnalysisState _state(
  BookAnalysisStatus status, {
  AnalysisProgress? progress,
}) => BookAnalysisState(
  bookHash: 'h',
  bookPath: '/p',
  addedAt: DateTime.utc(2026),
  status: status,
  progress: progress,
);

Future<void> _show(WidgetTester tester, BookAnalysisState? state) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AnalysisProgressBanner(state: state)),
      ),
    );

void main() {
  testWidgets(
    'waiting and failed states explain themselves without progress bars',
    (tester) async {
      await _show(tester, _state(BookAnalysisStatus.waitingConsent));
      expect(find.textContaining('illustration setup'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await _show(tester, _state(BookAnalysisStatus.failed));
      expect(find.textContaining('failed'), findsOneWidget);
    },
  );

  testWidgets('absent state renders nothing', (tester) async {
    await _show(tester, null);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('completed analysis is shown as full', (tester) async {
    await _show(tester, _state(BookAnalysisStatus.complete));
    expect(find.text('Book analysis complete'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      1,
    );
  });
}
