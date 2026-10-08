// Fake boundary behavior is documented at each owning type.
// ignore_for_file: public_member_api_docs
import 'dart:async';
import 'dart:typed_data';

import 'package:reader/models.dart';
import 'package:reader/narration/api.dart';
import 'package:reader/narration/models.dart';
import 'package:reader/narration/player.dart';
import 'package:reader/narration/store.dart';
import 'package:reader/text/narration.dart';

/// Offline cloud fake records generation; a gate exposes stale-download races.
class FakeNarrationApi implements NarrationApi {
  bool offline = false;
  int registrations = 0;
  int signOuts = 0, accountDeletions = 0;
  final List<NarrationChunk> requests = [];
  final List<String> voices = [];
  final List<String> deleted = [];
  Completer<Uint8List>? gate;
  @override
  bool get configured => true;
  @override
  Future<bool> hasSession() async => true;
  @override
  Future<Map<String, dynamic>> configuration() async => {
    'enabled': true,
    'remaining': 500000,
  };
  @override
  Future<NarrationRegistration> register(CatalogBook book) async {
    registrations++;
    return const NarrationRegistration('account', 'cloud-book', 500000);
  }

  @override
  Future<Uint8List> audio(
    String bookId,
    NarrationChunk chunk,
    String voice, {
    required bool Function() isCurrent,
  }) async {
    if (offline) throw StateError('Offline');
    requests.add(chunk);
    voices.add(voice);
    return gate == null ? testWav() : gate!.future;
  }

  @override
  Future<void> deleteBook(String bookId) async {
    if (offline) throw StateError('Offline');
    deleted.add(bookId);
  }

  @override
  Future<void> signOut() async {
    signOuts++;
  }

  @override
  Future<void> deleteAccount() async {
    if (offline) throw StateError('Offline');
    accountDeletions++;
  }
}

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

/// In-memory manifest/cache boundary for widget tests without filesystem work.
class MemoryNarrationStore implements NarrationStore {
  final manifests = <String, NarrationManifest>{};
  final files = <String, String>{};
  Set<String> pins = {};
  Completer<void>? clearGate;
  int saves = 0;
  @override
  Future<NarrationManifest> load(CatalogBook book) async =>
      manifests[book.hash] ?? const NarrationManifest();
  @override
  Future<void> save(CatalogBook book, NarrationManifest manifest) async {
    saves++;
    manifests[book.hash] = manifest;
  }

  @override
  Future<String?> cached(CatalogBook book, String key) async => files[key];
  @override
  Future<String> put(CatalogBook book, String key, Uint8List bytes) async {
    files[key] = '/cache/$key.wav';
    return files[key]!;
  }

  @override
  void pin(Set<String> keys) {
    pins = keys;
  }

  @override
  Future<int> cachedBytes(CatalogBook book) async =>
      files.length * testWav().length;

  @override
  Future<void> clear(CatalogBook book) async {
    await clearGate?.future;
    files.clear();
  }
}

/// Valid 24 kHz mono PCM WAV; native scenarios can use real offline audio.
Uint8List testWav({int samples = 24000}) {
  final bytes = Uint8List(44 + samples * 2);
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  bytes.setRange(8, 16, 'WAVEfmt '.codeUnits);
  bytes.setRange(36, 40, 'data'.codeUnits);
  final data = ByteData.sublistView(bytes);
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 24000, Endian.little);
  data.setUint32(28, 48000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, samples * 2, Endian.little);
  return bytes;
}
