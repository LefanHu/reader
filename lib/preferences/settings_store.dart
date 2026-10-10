import 'reader_settings.dart';

/// Persistence boundary for preferences that apply across publications.
abstract interface class SettingsStore {
  /// Restores global settings or their defaults.
  Future<ReaderSettings> load();

  /// Persists the complete global settings value.
  Future<void> save(ReaderSettings settings);
}
