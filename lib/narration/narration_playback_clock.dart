/// Token-bound source-media clock; speed affects wall time, not cue timestamps.
class NarrationPlaybackClock {
  /// Captures one actual player clock transition for a single load token.
  const NarrationPlaybackClock({
    required this.token,
    required this.position,
    required this.speed,
    required this.advancing,
  });

  /// Player load identity fencing stale events after source replacement.
  final int token;

  /// Actual source-media position sampled at the transition.
  final Duration position;

  /// Playback multiplier used to schedule media-boundary wall-clock delays.
  final double speed;

  /// True only while the loaded source is playing and ready, never buffering.
  final bool advancing;
}
