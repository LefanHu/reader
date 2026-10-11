import 'package:flutter/painting.dart';

import '../preferences/reader_settings.dart';

/// Body typography shared by every measured reader layout.
TextStyle readerTextStyle(ReaderSettings settings, Color foreground) =>
    TextStyle(
      fontFamily: settings.serif ? 'Lora' : 'DM Sans',
      fontSize: 20 * settings.fontSize / 100,
      height: 1.6,
      color: foreground,
    );
