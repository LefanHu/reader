import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'library.dart';
import 'theme.dart';

/// Initializes persistent state and starts the application.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    final notices = await rootBundle.loadString('THIRD_PARTY_NOTICES.md');
    yield LicenseEntryWithLineBreaks(const ['Flureadium', 'Readium'], notices);
  });
  final controller = await ReaderController.create();
  runApp(ReaderApp(controller: controller));
}

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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Persist the latest debounced locator before the process is suspended.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      widget.controller.flush();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Reader',
    debugShowCheckedModeBanner: false,
    theme: readerTheme,
    home: LibraryScreen(controller: widget.controller),
  );
}
