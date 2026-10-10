import 'dart:async';

/// Playback boundary: completion is a player event, never a seek/download event.
abstract interface class NarrationPlayer {
  /// Native media actions route back through the session's progress policy.
  void bind({
    required Future<void> Function() play,
    required Future<void> Function() pause,
    required Future<void> Function() stop,
    required Future<void> Function(Duration) seek,
  });

  /// Emits the load token on natural completion, rejecting stale native events.
  Stream<int> get completed;

  /// Current audio offset, used only for interrupted-chunk resume persistence.
  Duration get position;

  /// Current file duration for bounded ±15-second seeks.
  Duration? get duration;

  /// Replaces the native source; load token identifies its completion callback.
  Future<void> load(String path, String title, int token, Duration offset);

  /// Starts/resumes the loaded file without waiting for its ending.
  Future<void> resume();

  /// Freezes audio immediately; no text progress is committed.
  Future<void> pauseAudio();

  /// Releases the native audio source and media session.
  Future<void> stopAudio();

  /// Moves within audio only; seeking cannot commit the chunk's text anchor.
  Future<void> seekAudio(Duration offset);

  /// Uses the same cached file for any supported playback multiplier.
  Future<void> speed(double value);

  /// Releases this session's playback ownership; native service lives with the engine.
  Future<void> dispose();
}
