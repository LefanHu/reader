import 'dart:async';

import '../text/grapheme_boundary.dart';
import '../text/narration_playback_unit.dart';
import '../text/narration_range.dart';
import 'narration_cue.dart';
import 'narration_playback_clock.dart';
import 'narration_timing.dart';
import 'player.dart';

/// Presentation-only native cue selection against the file player's media clock.
///
/// Load tokens must increase within the owning session. Word start markers take
/// precedence over native sentence markers; neither implies an exact spoken end.
/// No progress is committed here, and no timer runs without an attached reader.
class NarrationHighlightTracker {
  /// Subscribes once to the engine-owned player, not to periodic position ticks.
  NarrationHighlightTracker({
    required NarrationPlayer player,
    required this._changed,
  }) : _player = player {
    _clocks = player.clockChanges.listen(_clockChanged);
    _completions = player.completed.listen(_completed);
  }

  final NarrationPlayer _player;
  final void Function() _changed;
  late final StreamSubscription<NarrationPlaybackClock> _clocks;
  late final StreamSubscription<int> _completions;
  NarrationPlaybackClock? _latestClock;
  NarrationPlaybackUnit? _unit;
  List<NarrationCue> _cues = const [];
  NarrationRange? _range;
  int? _token;
  Object? _owner;
  Timer? _timer;
  int _revision = 0;
  bool _disposed = false;

  /// Visible native bound, or the declared sentence when timing is unusable.
  /// Pausing, stalling, detaching and completion expose no stale decoration.
  NarrationRange? get range => _range;

  /// Whether the bound clip has a usable native word or sentence timeline.
  /// A fallback follows the clip start, not its enclosing sentence's start.
  bool get hasNativeTiming => _cues.isNotEmpty;

  /// Binds metadata to the same token used to load its exact audio clip.
  /// Early load/ready snapshots are retained and actual position is reread here.
  void load({
    required int token,
    required NarrationPlaybackUnit unit,
    required NarrationTiming? timing,
  }) {
    if (_disposed ||
        (_latestClock != null && token < _latestClock!.token) ||
        (_token != null && token < _token!)) {
      return;
    }
    _token = token;
    _unit = unit;
    _cues = _usableCues(unit, timing);
    _recompute();
  }

  List<NarrationCue> _usableCues(
    NarrationPlaybackUnit unit,
    NarrationTiming? timing,
  ) {
    final duration = _player.duration;
    if (timing == null ||
        duration == null ||
        !timing.matches(
          chunkId: unit.chunk.id,
          sourceDigest: unit.chunk.digest,
          duration: duration,
        )) {
      return const [];
    }
    if (timing.cues.isEmpty) return const [];
    final chunk = unit.chunk;
    final clip = NarrationRange(chunk.start, chunk.end);
    final boundaries = GraphemeBoundaries(chunk.text);
    final usable = <NarrationCue>[];
    var hasWords = false;
    for (final cue in timing.cues) {
      if (!clip.contains(cue.range) ||
          !boundaries.contains(cue.range.start.offset - chunk.start.offset) ||
          !boundaries.contains(cue.range.end.offset - chunk.start.offset)) {
        continue;
      }
      if (cue.kind == NarrationCueKind.word) {
        if (!hasWords) {
          usable.clear();
          hasWords = true;
        }
        usable.add(cue);
      } else if (!hasWords) {
        usable.add(cue);
      }
    }
    return usable;
  }

  /// Enables boundary scheduling for the current mounted reader owner.
  /// Reattachment recomputes from the current position without replaying audio.
  void attach(Object owner) {
    if (_disposed) return;
    _owner = owner;
    _recompute();
  }

  /// Only the identical owner may detach; an obsolete reader cannot detach a new one.
  void detach(Object owner) {
    if (_disposed || !identical(_owner, owner)) return;
    _owner = null;
    _recompute();
  }

  /// Unbinds the current clip, retaining any newer early-load clock snapshot.
  void clear() {
    _cancelTimer();
    _token = null;
    _unit = null;
    _cues = const [];
    _setRange(null);
  }

  void _clockChanged(NarrationPlaybackClock clock) {
    if (_disposed ||
        (_latestClock != null && clock.token < _latestClock!.token) ||
        (_token != null && clock.token < _token!)) {
      return;
    }
    _latestClock = clock;
    _recompute();
  }

  void _completed(int token) {
    if (_disposed) return;
    final clock = _latestClock;
    if (clock != null && clock.token == token) {
      _latestClock = NarrationPlaybackClock(
        token: token,
        position: _player.position,
        speed: clock.speed,
        advancing: false,
      );
    }
    if (_token == token) clear();
  }

  void _cancelTimer() {
    _revision++;
    _timer?.cancel();
    _timer = null;
  }

  void _recompute() {
    _cancelTimer();
    final clock = _latestClock;
    final unit = _unit;
    if (_disposed ||
        _owner == null ||
        unit == null ||
        clock == null ||
        clock.token != _token ||
        !clock.advancing ||
        !clock.speed.isFinite ||
        clock.speed <= 0) {
      _setRange(null);
      return;
    }
    final position = _player.position;
    final duration = _player.duration;
    if (position < Duration.zero ||
        (duration != null && position >= duration)) {
      _setRange(null);
      return;
    }
    if (_cues.isEmpty) {
      _setRange(unit.sentence);
      return;
    }

    // Upper bound: before the first start marker there is deliberately no wash.
    var low = 0;
    var high = _cues.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (_cues[middle].time <= position) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final revision = _revision;
    final owner = _owner;
    final token = _token;
    _setRange(low == 0 ? null : _cues[low - 1].range);
    if (revision != _revision) return;
    if (low == _cues.length) return;
    final delayUs = (_cues[low].time - position).inMicroseconds / clock.speed;
    if (!delayUs.isFinite) return;
    final delay = delayUs.ceil();
    _timer = Timer(Duration(microseconds: delay < 1000 ? 1000 : delay), () {
      if (_disposed ||
          revision != _revision ||
          token != _token ||
          !identical(owner, _owner)) {
        return;
      }
      _timer = null;
      _recompute();
    });
  }

  void _setRange(NarrationRange? value) {
    if (_range == value) return;
    _range = value;
    _changed();
  }

  /// Releases subscriptions and the sole boundary timer without owning the player.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _owner = null;
    clear();
    await _clocks.cancel();
    await _completions.cancel();
  }
}
