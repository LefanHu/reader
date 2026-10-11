import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/narration/narration_provider.dart';

import 'support/fake_narration_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('iOS uses cloud while on-device narration is disabled', () {
    expect(onDeviceNarrationEnabled, isFalse);
    expect(
      selectNarrationProvider(TargetPlatform.iOS),
      NarrationProvider.cloud,
    );
  });

  test('iOS uses on-device narration only when enabled', () {
    expect(
      selectNarrationProvider(TargetPlatform.iOS, onDeviceEnabled: true),
      NarrationProvider.onDevice,
    );
  });

  test('other platforms always use cloud narration', () {
    for (final platform in [TargetPlatform.macOS, TargetPlatform.android]) {
      expect(
        selectNarrationProvider(platform, onDeviceEnabled: true),
        NarrationProvider.cloud,
      );
    }
  });

  test('cloud source is built without native channel initialization', () async {
    final source = await createNarrationSource(
      NarrationProvider.cloud,
      root: Directory.systemTemp,
      api: FakeNarrationApi(),
    );
    expect(source.requiresCloudRegistration, isTrue);
  });
}
