import 'package:reader/preferences/reader_settings.dart';
import 'package:reader/preferences/settings_store.dart';

/// Preference store that exposes the last persisted value to assertions.
class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([this.settings = const ReaderSettings()]);
  ReaderSettings settings;
  @override
  Future<ReaderSettings> load() async => settings;
  @override
  Future<void> save(ReaderSettings value) async => settings = value;
}
