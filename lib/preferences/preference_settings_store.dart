import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'reader_settings.dart';
import 'settings_store.dart';

/// Stores global reader settings as one JSON value in SharedPreferences.
class PreferenceSettingsStore implements SettingsStore {
  static const _key = 'reader.settings.v1';
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();

  @override
  Future<ReaderSettings> load() async {
    final value = await _preferences.getString(_key);
    if (value == null) return const ReaderSettings();
    try {
      return ReaderSettings.fromJson(
        (jsonDecode(value) as Map).cast<String, dynamic>(),
      );
    } on Object {
      // A corrupt or older value must not prevent the library from opening.
      return const ReaderSettings();
    }
  }

  @override
  Future<void> save(ReaderSettings settings) =>
      _preferences.setString(_key, jsonEncode(settings.toJson()));
}
