import 'package:flutter_test/flutter_test.dart';
import 'package:reader/preferences/reader_preferences_coordinator.dart';
import 'package:reader/preferences/library_filter.dart';
import 'package:reader/preferences/library_sort.dart';
import 'package:reader/preferences/reader_settings.dart';
import 'package:reader/preferences/reading_mode.dart';
import 'package:reader/preferences/reading_theme.dart';

import 'support/memory_settings_store.dart';

void main() {
  test('page flip settings round trip without changing old defaults', () {
    const setting = ReaderSettings(mode: ReadingMode.pageFlip);
    expect(
      ReaderSettings.fromJson(setting.toJson()).mode,
      ReadingMode.pageFlip,
    );
    expect(ReaderSettings.fromJson({}).mode, ReadingMode.scroll);
    for (final mode in [ReadingMode.pages, ReadingMode.scroll]) {
      expect(ReaderSettings.fromJson({'mode': mode.name}).mode, mode);
    }
  });

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
    'Apple identities round trip even when an installed voice is removed',
    () {
      const identity = 'apple:fixture.voice.removed';
      final restored = ReaderSettings.fromJson(
        const ReaderSettings(narrationVoice: identity).toJson(),
      );
      expect(restored.narrationVoice, identity);
      expect(restored.copyWith(fontSize: 130).narrationVoice, identity);
      for (final invalid in ['apple:', 'apple:  ', 'unknown', 4]) {
        expect(
          ReaderSettings.fromJson({'narrationVoice': invalid}).narrationVoice,
          'marin',
        );
      }
    },
  );

  test(
    'new voice choices use the selected source catalog, not namespace alone',
    () async {
      final store = MemorySettingsStore(
        const ReaderSettings(narrationVoice: 'apple:removed'),
      );
      final applied = <ReaderSettings>[];
      final preferences = ReaderPreferencesCoordinator(
        store: store,
        applyNarrationPreferences: (settings) async => applied.add(settings),
        changed: () {},
        isNarrationVoiceAvailable: (voice) => voice == 'apple:installed',
        defaultNarrationVoice: () => 'apple:installed',
      );
      addTearDown(preferences.dispose);
      await preferences.load();
      expect(preferences.settings.narrationVoice, 'apple:removed');
      await preferences.configure(fontSize: 140);
      expect(preferences.settings.narrationVoice, 'apple:removed');
      for (final voice in ['marin', 'cedar', 'apple:not-installed']) {
        await expectLater(
          preferences.configure(narrationVoice: voice),
          throwsArgumentError,
        );
      }
      expect(applied, hasLength(1));
      await preferences.configure(narrationVoice: 'apple:installed');
      expect(store.settings.narrationVoice, 'apple:installed');
    },
  );

  test(
    'reset uses source default and preserves missing voice without a default',
    () async {
      for (final defaultVoice in <String?>['apple:preferred', 'marin', null]) {
        final store = MemorySettingsStore(
          const ReaderSettings(
            narrationVoice: 'apple:removed',
            narrationSpeed: 1.75,
            theme: ReadingTheme.dark,
            fontSize: 160,
          ),
        );
        final preferences = ReaderPreferencesCoordinator(
          store: store,
          applyNarrationPreferences: (_) async {},
          changed: () {},
          isNarrationVoiceAvailable: (voice) => voice == defaultVoice,
          defaultNarrationVoice: () => defaultVoice,
        );
        addTearDown(preferences.dispose);
        await preferences.load();
        await preferences.reset();
        expect(store.settings.narrationVoice, defaultVoice ?? 'apple:removed');
        expect(store.settings.narrationSpeed, 1);
        expect(store.settings.theme, ReadingTheme.paper);
        expect(store.settings.fontSize, 100);
      }
    },
  );
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
