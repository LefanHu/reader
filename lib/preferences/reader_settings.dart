import 'reading_mode.dart';
import 'reading_theme.dart';
import 'library_filter.dart';
import 'library_sort.dart';

/// Reader-wide preferences shared by every imported publication.
///
/// These values are persisted separately from the catalog so changing a book
/// record cannot reset the user's preferred reading experience.
class ReaderSettings {
  /// Creates settings, defaulting to scrolling serif text on paper.
  const ReaderSettings({
    this.mode = ReadingMode.scroll,
    this.theme = ReadingTheme.paper,
    this.fontSize = 100,
    this.serif = true,
    this.narrationVoice = 'marin',
    this.narrationSpeed = 1,
    this.libraryFilter = LibraryFilter.all,
    this.librarySort = LibrarySort.recent,
  });

  /// Active flow mode.
  final ReadingMode mode;

  /// Persisted app-wide color preset; also determines opaque page texture colors.
  final ReadingTheme theme;

  /// Reader font scale as an integer percentage.
  final int fontSize;

  /// Whether the viewport should prefer the bundled serif reading family.
  final bool serif;

  /// Global provider voice; book sidecars record audio identity, not overrides.
  final String narrationVoice;

  /// Global playback multiplier; changes reuse existing generated audio.
  final double narrationSpeed;

  /// Initial library subset; temporary library selections do not change it.
  final LibraryFilter libraryFilter;

  /// Initial library ordering across application sessions.
  final LibrarySort librarySort;

  /// Returns a new value with only the supplied fields replaced.
  ReaderSettings copyWith({
    ReadingMode? mode,
    ReadingTheme? theme,
    int? fontSize,
    bool? serif,
    String? narrationVoice,
    double? narrationSpeed,
    LibraryFilter? libraryFilter,
    LibrarySort? librarySort,
  }) => ReaderSettings(
    mode: mode ?? this.mode,
    theme: theme ?? this.theme,
    fontSize: fontSize ?? this.fontSize,
    serif: serif ?? this.serif,
    narrationVoice: narrationVoice ?? this.narrationVoice,
    narrationSpeed: narrationSpeed ?? this.narrationSpeed,
    libraryFilter: libraryFilter ?? this.libraryFilter,
    librarySort: librarySort ?? this.librarySort,
  );

  /// Serializes settings into the versioned value stored by [SettingsStore].
  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'theme': theme.name,
    'fontSize': fontSize,
    'serif': serif,
    'narrationVoice': narrationVoice,
    'narrationSpeed': narrationSpeed,
    'libraryFilter': libraryFilter.name,
    'librarySort': librarySort.name,
  };

  /// Restores settings while constraining text size to the supported range.
  factory ReaderSettings.fromJson(Map<String, dynamic> json) => ReaderSettings(
    mode: ReadingMode.values.byName(json['mode'] as String? ?? 'scroll'),
    theme: ReadingTheme.values.byName(json['theme'] as String? ?? 'paper'),
    fontSize: (json['fontSize'] as num?)?.round().clamp(80, 180) ?? 100,
    serif: json['serif'] as bool? ?? true,
    narrationVoice: ['marin', 'cedar'].contains(json['narrationVoice'])
        ? json['narrationVoice'] as String
        : 'marin',
    narrationSpeed:
        json['narrationSpeed'] is num &&
            (json['narrationSpeed'] as num).isFinite
        ? (json['narrationSpeed'] as num).toDouble().clamp(.75, 2)
        : 1,
    libraryFilter:
        LibraryFilter.values
            .where((value) => value.name == json['libraryFilter'])
            .firstOrNull ??
        LibraryFilter.all,
    librarySort:
        LibrarySort.values
            .where((value) => value.name == json['librarySort'])
            .firstOrNull ??
        LibrarySort.recent,
  );
}
