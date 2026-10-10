import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import 'player.dart';

/// One app-lifetime audio_service handler with native Apple media controls.
class NativeNarrationPlayer extends BaseAudioHandler
    implements NarrationPlayer {
  /// Initializes engine-owned streams; obtain the shared handler through [create].
  NativeNarrationPlayer() {
    _audio.playerStateStream.listen((state) {
      playbackState.add(
        playbackState.value.copyWith(
          controls: [
            MediaControl.rewind,
            state.playing ? MediaControl.pause : MediaControl.play,
            MediaControl.fastForward,
            MediaControl.stop,
          ],
          systemActions: {MediaAction.seek},
          processingState: switch (state.processingState) {
            ProcessingState.idle => AudioProcessingState.idle,
            ProcessingState.loading => AudioProcessingState.loading,
            ProcessingState.buffering => AudioProcessingState.buffering,
            ProcessingState.ready => AudioProcessingState.ready,
            ProcessingState.completed => AudioProcessingState.completed,
          },
          playing: state.playing,
          updatePosition: position,
          speed: _audio.speed,
        ),
      );
      if (state.processingState == ProcessingState.completed &&
          _token != null) {
        final token = _token!;
        _token = null;
        _completion.add(token);
      }
    });
    _audio.positionStream.listen((offset) {
      playbackState.add(playbackState.value.copyWith(updatePosition: offset));
    });
  }
  final AudioPlayer _audio = AudioPlayer(handleInterruptions: false);
  final StreamController<int> _completion = StreamController.broadcast();
  int? _token;
  Future<void> Function()? _playAction, _pauseAction, _stopAction;
  Future<void> Function(Duration)? _seekAction;

  // AudioService permits one initialization per engine, even across controllers.
  static Future<NativeNarrationPlayer>? _instance;

  /// Shares one native handler and spoken-audio configuration for the engine.
  static Future<NativeNarrationPlayer> create() => _instance ??= _create();

  static Future<NativeNarrationPlayer> _create() async {
    final handler = await AudioService.init(
      builder: NativeNarrationPlayer.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'reader.narration',
        androidNotificationChannelName: 'Book narration',
        fastForwardInterval: Duration(seconds: 15),
        rewindInterval: Duration(seconds: 15),
      ),
    );
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    session.interruptionEventStream.listen((event) {
      if (event.begin) unawaited(handler._pauseAction?.call());
    });
    session.becomingNoisyEventStream.listen((_) {
      unawaited(handler._pauseAction?.call());
    });
    return handler;
  }

  @override
  void bind({
    required Future<void> Function() play,
    required Future<void> Function() pause,
    required Future<void> Function() stop,
    required Future<void> Function(Duration) seek,
  }) {
    _playAction = play;
    _pauseAction = pause;
    _stopAction = stop;
    _seekAction = seek;
  }

  @override
  Stream<int> get completed => _completion.stream;
  @override
  Duration get position => _audio.position;
  @override
  Duration? get duration => _audio.duration;
  @override
  Future<void> load(
    String path,
    String title,
    int token,
    Duration offset,
  ) async {
    _token = null;
    await _audio.setFilePath(path);
    // A persisted offset at/beyond EOF must never turn loading into completion.
    final length = duration;
    if (offset > Duration.zero && length != null && offset < length) {
      await _audio.seek(offset);
    }
    _token = token;
    mediaItem.add(MediaItem(id: path, title: title, duration: duration));
  }

  @override
  Future<void> resume() async {
    unawaited(
      _audio.play().catchError((Object _) async {
        await _pauseAction?.call();
      }),
    );
  }

  @override
  Future<void> pauseAudio() => _audio.pause();
  @override
  Future<void> stopAudio() async {
    _token = null;
    await _audio.stop();
    mediaItem.add(null);
  }

  @override
  Future<void> seekAudio(Duration offset) => _audio.seek(offset);

  /// Publishes speed immediately; a speed-only edit need not emit player state.
  @override
  Future<void> speed(double value) async {
    await _audio.setSpeed(value);
    playbackState.add(
      playbackState.value.copyWith(
        speed: _audio.speed,
        updatePosition: position,
      ),
    );
  }

  @override
  Future<void> pause() async {
    await _pauseAction?.call();
  }

  @override
  Future<void> stop() async {
    await _stopAction?.call();
  }

  @override
  Future<void> seek(Duration position) async {
    await _seekAction?.call(position);
  }

  @override
  Future<void> play() async {
    await _playAction?.call();
  }

  @override
  Future<void> rewind() async {
    await _seekAction?.call(position - const Duration(seconds: 15));
  }

  @override
  Future<void> fastForward() async {
    await _seekAction?.call(position + const Duration(seconds: 15));
  }

  @override
  Future<void> onTaskRemoved() async {
    await _stopAction?.call();
  }

  /// Unbinds the closed session without reinitializing AudioService on the next one.
  @override
  Future<void> dispose() async {
    _token = null;
    _playAction = _pauseAction = _stopAction = null;
    _seekAction = null;
    if (_audio.processingState != ProcessingState.idle) {
      await stopAudio();
    }
  }
}
