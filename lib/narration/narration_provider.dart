import 'dart:io';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'apple_narration_source.dart';
import 'cloud_narration_source.dart';
import 'source.dart';

/// Narration implementations; each backs one [NarrationSource].
enum NarrationProvider {
  /// Apple on-device synthesis ([AppleNarrationSource]); iOS only.
  onDevice,

  /// Cloud synthesis behind Firebase Auth and App Check
  /// ([CloudNarrationSource]).
  cloud,
}

/// Build-time switch for Apple on-device narration.
///
/// Off because the Apple voices were judged too poor to ship; the
/// implementation is retained. Re-enable with
/// `--dart-define=ON_DEVICE_NARRATION_ENABLED=true`.
const onDeviceNarrationEnabled = bool.fromEnvironment(
  'ON_DEVICE_NARRATION_ENABLED',
);

/// Chooses the provider for [platform].
///
/// On-device is used only on iOS and only when [onDeviceEnabled]; every other
/// platform, and iOS while on-device is disabled, uses cloud.
NarrationProvider selectNarrationProvider(
  TargetPlatform platform, {
  bool onDeviceEnabled = onDeviceNarrationEnabled,
}) => platform == TargetPlatform.iOS && onDeviceEnabled
    ? NarrationProvider.onDevice
    : NarrationProvider.cloud;

/// Builds the source for [provider].
///
/// On-device initializes the native `reader/narration` channel and binds
/// [root]; cloud performs no native initialization.
Future<NarrationSource> createNarrationSource(
  NarrationProvider provider, {
  required Directory root,
  required NarrationApi api,
}) async => switch (provider) {
  NarrationProvider.onDevice => await AppleNarrationSource.create(root: root),
  NarrationProvider.cloud => CloudNarrationSource(api),
};
