// Fake boundary behavior is documented at each owning type.
// ignore_for_file: public_member_api_docs
import 'dart:async';

import 'package:reader/narration/player.dart';

/// Native fake keeps explicit completion distinct from audio seeking and pause.
class FakeNarrationPlayer implements NarrationPlayer {
  final completion = StreamController<int>.broadcast();
  int? token;
  bool playing = false;
  double multiplier = 1;
  Duration loadedOffset = Duration.zero;
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
  Duration position = Duration.zero;
  @override
  Duration? get duration => const Duration(seconds: 30);
  @override
  Future<void> load(
    String path,
    String title,
    int token,
    Duration offset,
  ) async {
    this.token = token;
    loadedOffset = offset;
    position = offset;
  }

  @override
  Future<void> resume() async {
    playing = true;
  }

  @override
  Future<void> pauseAudio() async {
    playing = false;
  }

  @override
  Future<void> stopAudio() async {
    playing = false;
    token = null;
  }

  @override
  Future<void> seekAudio(Duration offset) async {
    position = offset;
  }

  @override
  Future<void> speed(double value) async {
    multiplier = value;
  }

  @override
  Future<void> dispose() => completion.close();
  void finish([int? oldToken]) => completion.add(oldToken ?? token!);
}
