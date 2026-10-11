import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _dictionaryChannel = MethodChannel('reader/dictionary');

/// Presents the local OS dictionary for the exact selected normalized [text].
///
/// [anchor] is the visible word's rectangle in Flutter-view-global logical
/// coordinates, not screen coordinates or device pixels. The native bridge owns
/// presentation and its lifecycle; it neither stores prose nor changes reading
/// position. Completion means the OS presentation API was invoked (and, on iOS,
/// presentation completed), not that a definition exists or the UI was dismissed.
/// Native presentation errors and unsupported-platform errors propagate unchanged.
Future<void> lookupDictionary(String text, Rect anchor) async {
  await _dictionaryChannel.invokeMethod<void>('lookUp', <String, Object>{
    'text': text,
    'x': anchor.left,
    'y': anchor.top,
    'width': anchor.width,
    'height': anchor.height,
  });
}

/// Dismisses only this bridge's outstanding UIKit dictionary presentation.
///
/// Selection-owner cleanup must not close unrelated native controllers. AppKit
/// owns its nonmodal overlay's dismissal, so this is intentionally iOS-only.
/// Completion awaits UIKit dismissal; native cleanup errors propagate unchanged.
Future<void> dismissDictionary() async {
  if (defaultTargetPlatform != TargetPlatform.iOS || kIsWeb) return;
  await _dictionaryChannel.invokeMethod<void>('dismiss');
}
