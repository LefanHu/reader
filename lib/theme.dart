import 'package:flutter/material.dart';

/// Primary paper surface used by the library and default reading theme.
const paper = Color(0xFFF7F4ED);

/// High-contrast text and control color used on light surfaces.
const ink = Color(0xFF292E29);

/// Muted terracotta accent used for progress and primary highlights.
const accent = Color(0xFFAA573E);

/// Application theme with accessible 48-pixel primary control targets.
final readerTheme = ThemeData(
  useMaterial3: true,
  fontFamily: 'DM Sans',
  scaffoldBackgroundColor: paper,
  colorScheme: ColorScheme.fromSeed(
    seedColor: accent,
    surface: paper,
  ).copyWith(onSurface: ink),
  dividerColor: const Color(0xFFE0DCD2),
  iconButtonTheme: IconButtonThemeData(
    style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: ink,
      foregroundColor: paper,
      minimumSize: const Size(48, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  ),
);
