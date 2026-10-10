import 'package:flutter/material.dart';

import 'preferences/reading_theme.dart';

/// Default paper background, also used for the reader's opaque page textures.
const paper = Color(0xFFF7F4ED);

/// Default paper ink; other presets supply their own contrasting ink.
const ink = Color(0xFF292E29);

/// Default terracotta accent for understated selection and progress.
const accent = Color(0xFFAA573E);

/// Builds the shared library, reader, and overlay palette for a saved preset.
/// Explicit surface colors prevent Material's seed tint from coloring paper pink.
/// Reading typography preferences never change interface typography.
ThemeData buildReaderTheme(ReadingTheme preset) {
  final (
    background,
    surface,
    foreground,
    muted,
    border,
    highlight,
  ) = switch (preset) {
    ReadingTheme.paper => (
      paper,
      const Color(0xFFF0EDE5),
      ink,
      const Color(0xFF64685F),
      const Color(0xFFDAD7CD),
      accent,
    ),
    ReadingTheme.sepia => (
      const Color(0xFFF0E1C2),
      const Color(0xFFE7D5B1),
      const Color(0xFF382F24),
      const Color(0xFF665640),
      const Color(0xFFC9B792),
      const Color(0xFF8D4F30),
    ),
    ReadingTheme.dark => (
      const Color(0xFF171A18),
      const Color(0xFF222823),
      const Color(0xFFE8E3D8),
      const Color(0xFFAFB6AC),
      const Color(0xFF414940),
      const Color(0xFFD99975),
    ),
  };
  final scheme =
      ColorScheme.fromSeed(
        seedColor: highlight,
        brightness: preset == ReadingTheme.dark
            ? Brightness.dark
            : Brightness.light,
      ).copyWith(
        primary: highlight,
        onPrimary: preset == ReadingTheme.dark
            ? const Color(0xFF211D19)
            : Colors.white,
        primaryContainer: surface,
        onPrimaryContainer: foreground,
        secondary: highlight,
        onSecondary: preset == ReadingTheme.dark
            ? const Color(0xFF211D19)
            : Colors.white,
        secondaryContainer: surface,
        onSecondaryContainer: foreground,
        surface: background,
        onSurface: foreground,
        onSurfaceVariant: muted,
        surfaceContainerLowest: background,
        surfaceContainerLow: surface,
        surfaceContainer: surface,
        surfaceContainerHigh: surface,
        surfaceContainerHighest: surface,
        surfaceTint: Colors.transparent,
        outline: muted,
        outlineVariant: border,
        inverseSurface: foreground,
        onInverseSurface: background,
        inversePrimary: highlight,
      );
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'DM Sans',
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    dividerColor: border,
    iconTheme: IconThemeData(color: foreground),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    cardTheme: CardThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: background,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: highlight, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: foreground,
        foregroundColor: background,
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: muted,
      textColor: foreground,
      selectedColor: foreground,
      selectedTileColor: foreground.withValues(alpha: .06),
    ),
  );
}

/// Paper theme for standalone surfaces and tests without a session controller.
final readerTheme = buildReaderTheme(ReadingTheme.paper);
