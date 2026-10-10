import 'package:flutter/foundation.dart';

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
  });

  /// Persists complete reader-wide preference snapshots.
  final SettingsStore store;

  /// Authoritative current preferences, merged inside each queued operation.
  ReaderSettings settings = const ReaderSettings();

  final Future<void> Function(ReaderSettings) _applyNarrationPreferences;
  final VoidCallback _changed;
  Future<void> _preferenceTail = Future.value();
  int _pendingPreferences = 0;
  bool _disposed = false;

  /// Restores preferences without publishing a startup notification.
  Future<void> load() async {
    settings = await store.load();
  }

  /// Number of scheduled preference operations not yet completed.
  int get pendingOperations => _pendingPreferences;

  /// Awaits the serialization barrier without replaying operation errors.
  Future<void> flush() => _preferenceTail;

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
    if (narrationVoice != null &&
        !['marin', 'cedar'].contains(narrationVoice)) {
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

  /// Restores defaults without removing books, consent, or cached audio.
  Future<void> reset() => _updatePreferences((_) => const ReaderSettings());

  Future<void> _updatePreferences(
    ReaderSettings Function(ReaderSettings) update,
  ) {
    if (_disposed) return Future.value();
    _pendingPreferences++;
    // Serialize complete snapshots and native playback updates so rapid
    // controls cannot persist older values after a later selection.
    final operation = _preferenceTail.then((_) async {
      try {
        final next = update(settings);
        settings = next;
        if (!_disposed) _changed();
        try {
          await _applyNarrationPreferences(next);
        } finally {
          await store.save(next);
        }
      } finally {
        _pendingPreferences--;
      }
    });
    _preferenceTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  /// Stops scheduling and notifications without cancelling pending operations.
  void dispose() {
    _disposed = true;
  }
}
