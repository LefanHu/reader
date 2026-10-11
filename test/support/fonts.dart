import 'package:flutter/services.dart';

/// Loads the bundled reader fonts so goldens render real glyphs.
Future<void> loadReaderFonts() async {
  for (final (family, path) in [
    ('Lora', 'assets/fonts/Lora.ttf'),
    ('DM Sans', 'assets/fonts/DMSans.ttf'),
    ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
  ]) {
    await (FontLoader(family)..addFont(rootBundle.load(path))).load();
  }
}
