import 'reading_mode.dart';
import 'reading_theme.dart';
import 'library_filter.dart';
import 'library_sort.dart';

/// Playback speeds offered by Settings and the listening sheet, which write
/// the same preference; a saved speed stays within the first and last.
const narrationSpeeds = [.75, 1.0, 1.25, 1.5, 1.75, 2.0];

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

  /// Global source voice: Marin/Cedar or `apple:<installed identifier>`.
  /// Book sidecars record audio identity, never a preference override.
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

  /// Serializes settings into the value stored by [SettingsStore].
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
    narrationVoice: _voiceIdentity(json['narrationVoice']) ?? 'marin',
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

  // Parsing preserves removed Apple voices; availability belongs to the source,
  // not persisted settings, and must never silently change a saved selection.
  static String? _voiceIdentity(Object? value) {
    if (value == 'marin' || value == 'cedar') return value as String;
    if (value is String &&
        value.startsWith('apple:') &&
        value.substring(6).trim().isNotEmpty) {
      return value;
    }
    return null;
  }
}
