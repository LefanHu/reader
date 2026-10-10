import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/reader_controller.dart';
import 'app/reader_app.dart';

/// Initializes persistent state and starts the application.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    final notices = await rootBundle.loadString('THIRD_PARTY_NOTICES.md');
    yield LicenseEntryWithLineBreaks(const ['Reader dependencies'], notices);
    yield LicenseEntryWithLineBreaks(const [
      'Unicode data',
    ], await rootBundle.loadString('assets/licenses/Unicode-LICENSE.txt'));
  });
  final controller = await ReaderController.create();
  runApp(ReaderApp(controller: controller));
}
