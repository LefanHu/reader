import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Per-test budget for dev-API tests: real round trips plus token minting.
const devApiTimeout = Timeout(Duration(minutes: 2));

/// Deployed dev backend configuration read from the Git-ignored
/// `.dart-defines/dev.json` that `tool/deploy_backend dev` generates.
///
/// `flutter test` runs with the package root as the working directory, so the
/// file is resolved relative to [Directory.current].
class DevApiEnvironment {
  DevApiEnvironment._({required this.baseUri, required this.apiKey});

  /// Lazily loaded once per test isolate; throws [StateError] when missing.
  static final DevApiEnvironment instance = _load();

  /// Dev API origin (`ILLUSTRATION_API_BASE_URL`); clients resolve `/api/...`.
  final Uri baseUri;

  /// Public Firebase web API key used for Identity Toolkit REST calls.
  final String apiKey;

  /// iOS bundle the dev API key is restricted to.
  final String bundleId = 'com.leafmealone.reader';

  static DevApiEnvironment _load() {
    const missing =
        'Dev API tests need .dart-defines/dev.json from tool/deploy_backend dev.';
    final file = File('${Directory.current.path}/.dart-defines/dev.json');
    if (!file.existsSync()) throw StateError(missing);
    final defines = jsonDecode(file.readAsStringSync());
    if (defines is! Map) throw StateError(missing);
    final base = defines['ILLUSTRATION_API_BASE_URL'];
    final key = defines['FIREBASE_API_KEY'];
    if (base is! String || base.isEmpty || key is! String || key.isEmpty) {
      throw StateError(missing);
    }
    return DevApiEnvironment._(baseUri: Uri.parse(base), apiKey: key);
  }
}
