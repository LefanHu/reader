import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate' as dart_isolate;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reader/importing/import_candidate.dart';
import 'package:reader/importing/import_result.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/preferences/reading_theme.dart';
import 'package:reader/text/document_store.dart';
import 'package:reader/text/viewport.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import '../../test/support/fake_picker.dart';
import '../../test/fixtures/performance_book.dart';
import '../support/native_test_app.dart';
import '../support/performance_capture.dart';

/// Registers an isolated, offline workload, separate from debug correctness tests.
void registerPerformanceTests(IntegrationTestWidgetsFlutterBinding binding) {
  testWidgets('profiles the fixed imported mixed-script book', (tester) async {
    if (!kProfileMode) {
      fail('Use flutter drive --profile --no-dds with the performance driver.');
    }
    final app = await NativeTestApp.launch(tester, importBooks: false);
    final bytes = performanceBookFixture();
    (app.controller.catalog.picker as FakePicker).files = [
      ImportCandidate(
        name: 'Profile.epub',
        size: bytes.length,
        readBytes: () async => bytes,
      ),
    ];
    final imported = await app.controller.catalog.pickAndImport();
    expect(imported.single.status, ImportStatus.imported);
    await tester.pumpAndSettle();
    final book = app.book('Novel');
    final document = await TextDocumentStore().load(book.path);
    final start = document.contents.single.position!;
    final chapter = document.contents.single.children.single.position!;
    final serviceInfo = await developer.Service.getInfo();
    final uri = serviceInfo.serverUri;
    if (uri == null) fail('Profile mode must expose a VM service.');
    final service = await vmServiceConnectUri(
      uri.replace(scheme: 'ws', path: '${uri.path}ws').toString(),
    );
    addTearDown(service.dispose);
    final isolate = developer.Service.getIsolateId(
      dart_isolate.Isolate.current,
    )!;
    final view = tester.view;
    // Versioned report metadata identifies workload, settings, and frame budget.
    // Actual window/display dimensions are recorded rather than silently resized.
    binding.reportData = {
      'schema_version': 1,
      'complete': false,
      'metadata': {
        'fixture_version': performanceFixtureVersion,
        'paragraph_count': performanceParagraphCount,
        'source_hash': book.hash,
        'document_version': document.version,
        'platform': Platform.operatingSystem,
        'os_version': Platform.operatingSystemVersion,
        'dart_version': Platform.version,
        'logical_width': view.physicalSize.width / view.devicePixelRatio,
        'logical_height': view.physicalSize.height / view.devicePixelRatio,
        'device_pixel_ratio': view.devicePixelRatio,
        'refresh_rate_hz': view.display.refreshRate,
        'frame_policy': binding.framePolicy.name,
        'theme': 'paper',
        'font_size_percent': 100,
        'serif': true,
        'repetitions': 2,
        'scroll_gestures': 12,
        'scroll_distance': 450,
        'scroll_duration_ms': 300,
        'page_turns': 8,
      },
      'phases': <String, Object?>{},
    };

    // Reset the committed anchor outside timing: each repetition starts at the
    // same prose, instead of reopening wherever the previous chapter jump ended.
    for (var repeat = 0; repeat < 2; repeat++) {
      await app.controller.preferences.configure(
        mode: ReadingMode.scroll,
        theme: ReadingTheme.paper,
        fontSize: 100,
        serif: true,
      );
      await app.controller.savePosition(app.book('Novel'), start, 0);
      await app.controller.flush();
      await tester.pumpAndSettle();
      Future<void> measure(String phase, Future<void> Function() action) =>
          _capturePhase(
            binding,
            tester,
            service,
            isolate,
            '${phase}_$repeat',
            action,
          );
      await measure('open', () => app.openBook('Novel'));
      expect(app.viewport.navigation.leadingPosition, start);
      await measure('scroll', () async {
        for (var i = 0; i < 12; i++) {
          final before = app.viewport.navigation.leadingPosition;
          await tester.timedDrag(
            find.byType(TextViewport),
            const ui.Offset(0, -450),
            const Duration(milliseconds: 300),
          );
          await tester.pumpAndSettle();
          expect(app.viewport.navigation.leadingPosition, isNot(before));
        }
      });
      if (repeat == 1) await app.capture('performance-scroll');
      // Async polling must not call the tester's guarded widget lookup mid-pump.
      final navigation = app.viewport.navigation;
      final turnStart = navigation.leadingPosition!;
      await app.controller.preferences.configure(mode: ReadingMode.pageFlip);
      await tester.pumpAndSettle();
      // Reflow can await sidecar I/O after pumpAndSettle sees no scheduled frame.
      await app.runWithFrames(() => navigation.restore(turnStart));
      await measure('turn', () async {
        for (var i = 0; i < 8; i++) {
          final before = navigation.leadingPosition;
          await app.runWithFrames(() async {
            navigation.next();
            // Texture readback can also be pending between scheduled frames.
            while (navigation.leadingPosition == before) {
              await Future<void>.delayed(const Duration(milliseconds: 16));
            }
          });
          await tester.pumpAndSettle(const Duration(milliseconds: 16));
          expect(navigation.leadingPosition, isNot(before));
        }
      });
      await measure('chapter', () async {
        await tester.tap(find.byTooltip('Choose chapter'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Passage'));
        await app.runWithFrames(() async {
          while (navigation.leadingPosition != chapter) {
            await Future<void>.delayed(const Duration(milliseconds: 16));
          }
        });
        await tester.pumpAndSettle();
      });
      expect(navigation.leadingPosition, chapter);
      if (repeat == 1) await app.capture('performance-chapter');
      await app.closeReader();
    }
    expect(tester.takeException(), isNull);
    binding.reportData!['complete'] = true;
  });
}

/// Captures only the action, excluding setup, screenshot readback, and artifact I/O.
/// Timings arrive in engine batches; flush before/after, never fabricate empty data.
Future<void> _capturePhase(
  IntegrationTestWidgetsFlutterBinding binding,
  WidgetTester tester,
  VmService service,
  String isolate,
  String name,
  Future<void> Function() action,
) async {
  debugPrint('Performance phase: $name');
  await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
  final frames = <ui.FrameTiming>[];
  final activeFrames = <int>{};
  var recording = false;
  // Join delayed raster timings to engine frames observed during the action.
  // Frame numbers share engine identity; scheduler and timing stamps may differ.
  void markFrame(Duration _) {
    if (!recording) return;
    activeFrames.add(binding.platformDispatcher.frameData.frameNumber);
    binding.addPostFrameCallback(markFrame);
  }

  void record(List<ui.FrameTiming> batch) => frames.addAll(batch);
  binding.addTimingsCallback(record);
  try {
    await service.clearCpuSamples(isolate);
    final timeline = await binding.traceTimeline(() async {
      recording = true;
      binding.addPostFrameCallback(markFrame);
      try {
        await action();
      } finally {
        recording = false;
      }
    }, streams: ['Dart', 'Embedder', 'GC']);
    final cpu = await service.getCpuSamples(
      isolate,
      timeline.timeOriginMicros!,
      timeline.timeExtentMicros!,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    frames.removeWhere((frame) => !activeFrames.contains(frame.frameNumber));
    if (frames.isEmpty) {
      fail('No action frame timings captured for $name.');
    }
    compactCpuSamples(cpu);
    (binding.reportData!['phases'] as Map<String, Object?>)[name] = {
      'timeline': timeline.toJson(),
      'cpu': cpu.toJson(),
      // Keep engine identities and microsecond durations for raw re-analysis.
      'frames': [
        for (final frame in frames)
          {
            'frame_number': frame.frameNumber,
            'vsync_start_us': frame.timestampInMicroseconds(
              ui.FramePhase.vsyncStart,
            ),
            'build_us': frame.buildDuration.inMicroseconds,
            'raster_us': frame.rasterDuration.inMicroseconds,
            'total_us': frame.totalSpan.inMicroseconds,
          },
      ],
    };
  } finally {
    recording = false;
    binding.removeTimingsCallback(record);
    await service.setVMTimelineFlags([]);
  }
}
