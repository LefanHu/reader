import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../library/library_screen.dart';
import '../settings/settings_navigation.dart';
import '../theme.dart';
import 'reader_controller.dart';

/// Root widget responsible for app-wide theme and lifecycle persistence.
class ReaderApp extends StatefulWidget {
  /// Creates the application around an initialized shared [controller].
  const ReaderApp({super.key, required this.controller});

  /// Session controller retained for the lifetime of the application.
  final ReaderController controller;
  @override
  State<ReaderApp> createState() => _ReaderAppState();
}

class _ReaderAppState extends State<ReaderApp> with WidgetsBindingObserver {
  final _navigator = GlobalKey<NavigatorState>();
  static const _settingsChannel = MethodChannel('reader/settings');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settingsChannel.setMethodCallHandler((call) async {
      if (call.method == 'openSettings' && _navigator.currentState != null) {
        unawaited(
          SettingsNavigation.open(_navigator.currentState!, widget.controller),
        );
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Persist the latest debounced text position before the process is suspended.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(widget.controller.flush());
    }
    if (state == AppLifecycleState.detached) {
      unawaited(widget.controller.narration?.stop(restore: false));
    }
  }

  @override
  void dispose() {
    _settingsChannel.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => MaterialApp(
      title: 'Reader',
      navigatorKey: _navigator,
      debugShowCheckedModeBanner: false,
      // Switch all routes and overlays together; interpolated ink would trigger
      // repeated text reflows while the application's surfaces catch up.
      themeAnimationDuration: Duration.zero,
      theme: buildReaderTheme(widget.controller.preferences.settings.theme),
      home: LibraryScreen(controller: widget.controller),
    ),
  );
}
