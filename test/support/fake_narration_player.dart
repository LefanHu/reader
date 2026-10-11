// Fake boundary behavior is documented at each owning type.
// ignore_for_file: public_member_api_docs
import 'dart:async';

import 'package:reader/narration/player.dart';
import 'package:reader/narration/narration_playback_clock.dart';

/// Native fake keeps explicit completion distinct from audio seeking and pause.
class FakeNarrationPlayer implements NarrationPlayer {
  final completion = StreamController<int>.broadcast();
  final clocks = StreamController<NarrationPlaybackClock>.broadcast();
  int? token;
  bool playing = false;
  bool ready = true;
  double multiplier = 1;
  Duration loadedOffset = Duration.zero;
  Duration? length = const Duration(seconds: 30);
  Future<void> Function()? remotePlay, remotePause, remoteStop;
  Future<void> Function(Duration)? remoteSeek;
  @override
  void bind({
    required Future<void> Function() play,
    required Future<void> Function() pause,
    required Future<void> Function() stop,
    required Future<void> Function(Duration) seek,
  }) {
    remotePlay = play;
    remotePause = pause;
    remoteStop = stop;
    remoteSeek = seek;
  }

  @override
  Stream<int> get completed => completion.stream;
  @override
  Stream<NarrationPlaybackClock> get clockChanges => clocks.stream;
  @override
  Duration position = Duration.zero;
  @override
  Duration? get duration => length;
  @override
  Future<void> load(
    String path,
    String title,
    int token,
    Duration offset,
  ) async {
    emitClock(advancing: false);
    this.token = token;
    loadedOffset = offset;
    position = offset;
    ready = true;
    emitClock();
  }

  @override
  Future<void> resume() async {
    playing = true;
    emitClock();
  }

  @override
  Future<void> pauseAudio() async {
    playing = false;
    emitClock();
  }

  @override
  Future<void> stopAudio() async {
    playing = false;
    emitClock(advancing: false);
    ready = false;
    token = null;
  }

  @override
  Future<void> seekAudio(Duration offset) async {
    position = offset;
    emitClock();
  }

  @override
  Future<void> speed(double value) async {
    multiplier = value;
    emitClock();
  }

  @override
  Future<void> dispose() async {
    await completion.close();
    await clocks.close();
  }

  void emitClock({bool? advancing}) {
    final token = this.token;
    if (token == null) return;
    clocks.add(
      NarrationPlaybackClock(
        token: token,
        position: position,
        speed: multiplier,
        advancing: advancing ?? (playing && ready),
      ),
    );
  }

  void finish([int? oldToken]) {
    final completedToken = oldToken ?? token!;
    if (completedToken == token) {
      playing = false;
      ready = false;
      emitClock();
      token = null;
    }
    completion.add(completedToken);
  }
}
