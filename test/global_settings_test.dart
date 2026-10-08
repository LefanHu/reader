import 'package:flutter_test/flutter_test.dart';
import 'package:reader/models.dart';

void main() {
  test('older preferences restore global narration and library defaults', () {
    final settings = ReaderSettings.fromJson({
      'mode': 'pages',
      'theme': 'sepia',
      'fontSize': 120,
      'serif': false,
    });
    expect(settings.mode, ReadingMode.pages);
    expect(settings.narrationVoice, 'marin');
    expect(settings.narrationSpeed, 1);
    expect(settings.libraryFilter, LibraryFilter.all);
    expect(settings.librarySort, LibrarySort.recent);
  });
  test('global narration and library preferences round trip independently of books', () {
    final settings = ReaderSettings.fromJson(
      const ReaderSettings(
        narrationVoice: 'cedar',
        narrationSpeed: 1.75,
        libraryFilter: LibraryFilter.finished,
        librarySort: LibrarySort.title,
      ).toJson(),
    );
    expect(settings.narrationVoice, 'cedar');
    expect(settings.narrationSpeed, 1.75);
    expect(settings.libraryFilter, LibraryFilter.finished);
    expect(settings.librarySort, LibrarySort.title);
    expect(settings.copyWith(theme: ReadingTheme.dark).narrationVoice, 'cedar');
  });
  test(
    'malformed additive preferences fall back safely and bound playback speed',
    () {
      final settings = ReaderSettings.fromJson({
        'narrationVoice': 'unknown',
        'narrationSpeed': double.nan,
        'libraryFilter': 'unknown',
        'librarySort': 9,
      });
      expect(settings.narrationVoice, 'marin');
      expect(settings.narrationSpeed, 1);
      expect(settings.libraryFilter, LibraryFilter.all);
      expect(settings.librarySort, LibrarySort.recent);
      expect(ReaderSettings.fromJson({'narrationSpeed': 9}).narrationSpeed, 2);
      expect(
        ReaderSettings.fromJson({'narrationSpeed': .1}).narrationSpeed,
        .75,
      );
    },
  );
}
