import 'package:flutter/foundation.dart';

import '../serial_queue.dart';

import 'library_filter.dart';
import 'library_sort.dart';
import 'reader_settings.dart';
import 'reading_mode.dart';
import 'reading_theme.dart';
import 'settings_store.dart';

/// Owns global preferences and serializes persistence with native audio updates.
///
/// Queued operations finish after disposal, but disposed notifications stop.
/// Native failures still persist the selected preferences and reach the caller;
/// the serialization tail swallows them only to allow subsequent operations.
class ReaderPreferencesCoordinator {
  /// Installs persistence, live narration application, and shared notifications.
  ReaderPreferencesCoordinator({
    required this.store,
    required this._applyNarrationPreferences,
    required this._changed,
    required this.isNarrationVoiceAvailable,
    required this.defaultNarrationVoice,
  });

  /// Persists complete reader-wide preference snapshots.
  final SettingsStore store;

  /// Validates new selections against the active source's installed catalog.
  /// Restored missing voices remain unchanged until the user chooses a voice.
  final bool Function(String) isNarrationVoiceAvailable;

  /// Supplies the active source's default, or null when none is available.
  final String? Function() defaultNarrationVoice;

  /// Authoritative current preferences, merged inside each queued operation.
  ReaderSettings settings = const ReaderSettings();

  final Future<void> Function(ReaderSettings) _applyNarrationPreferences;
  final VoidCallback _changed;
  final _queue = SerialQueue();
  bool _disposed = false;

  /// Restores preferences without publishing a startup notification.
  Future<void> load() async {
    settings = await store.load();
  }

  /// Number of scheduled preference operations not yet completed.
  int get pendingOperations => _queue.pending;

  /// Awaits the serialization barrier without replaying operation errors.
  Future<void> flush() => _queue.idle;

  /// Applies and persists supplied values, retaining validation after disposal.
  Future<void> configure({
    ReadingMode? mode,
    ReadingTheme? theme,
    int? fontSize,
    bool? serif,
    String? narrationVoice,
    double? narrationSpeed,
    LibraryFilter? libraryFilter,
    LibrarySort? librarySort,
  }) {
    if (narrationVoice != null && !isNarrationVoiceAvailable(narrationVoice)) {
      return Future.error(
        ArgumentError.value(narrationVoice, 'narrationVoice'),
      );
    }
    if (narrationSpeed != null &&
        (!narrationSpeed.isFinite ||
            narrationSpeed < .75 ||
            narrationSpeed > 2)) {
      return Future.error(
        ArgumentError.value(narrationSpeed, 'narrationSpeed'),
      );
    }
    return _updatePreferences(
      (current) => current.copyWith(
        mode: mode,
        theme: theme,
        fontSize: fontSize,
        serif: serif,
        narrationVoice: narrationVoice,
        narrationSpeed: narrationSpeed,
        libraryFilter: libraryFilter,
        librarySort: librarySort,
      ),
    );
  }

  /// Restores defaults without removing books, illustration consent, or audio.
  Future<void> reset() => _updatePreferences(
    (current) => ReaderSettings(
      narrationVoice: defaultNarrationVoice() ?? current.narrationVoice,
    ),
  );

  Future<void> _updatePreferences(
    ReaderSettings Function(ReaderSettings) update,
  ) {
    if (_disposed) return Future.value();
    // Serialize complete snapshots and native playback updates so rapid
    // controls cannot persist older values after a later selection.
    return _queue.run(() async {
      final next = update(settings);
      settings = next;
      if (!_disposed) _changed();
      try {
        await _applyNarrationPreferences(next);
      } finally {
        await store.save(next);
      }
    });
  }

  /// Stops scheduling and notifications without cancelling pending operations.
  void dispose() {
    _disposed = true;
  }
}
