import 'dart:async';

import '../models.dart';
import '../text/document.dart';
import '../text/narration.dart';
import 'api.dart';
import 'models.dart';
import 'player.dart';
import 'store.dart';

/// Session status separates cloud buffering from committed reading progress.
enum NarrationStatus {
  /// No publication is attached.
  idle,

  /// Listening is suspended; its logical anchor may be restored to the viewport.
  paused,

  /// Waiting for an exact chunk; Retry resumes without losing the anchor.
  buffering,

  /// Native audio owns the active chunk and committed position writes.
  playing,

  /// The final chunk naturally completed and committed end-of-book progress.
  complete,
}

/// App-lifetime coordinator injected into the shared reader controller.
/// Only natural completion commits prose. Epochs fence downloads and native
/// callbacks; at most the active chunk plus two prefetched files are pinned.
class NarrationSession {
  /// Controller callbacks own catalog persistence and viewport restoration.
  NarrationSession({
    required this.api,
    required this.player,
    required this.store,
    required this.changed,
    required this.commit,
    required this.currentPosition,
    TextDocumentStore? documents,
    this.abandonRegistration,
    ReaderSettings Function()? preferences,
    bool Function(CatalogBook)? isBookAvailable,
  }) : isBookAvailable = isBookAvailable ?? ((_) => true),
       preferences = preferences ?? (() => const ReaderSettings()),
       documents = documents ?? TextDocumentStore() {
    player.bind(play: play, pause: pause, stop: stop, seek: seek);
    _subscription = player.completed.listen((token) {
      unawaited(
        _finished(token).catchError((Object failure) {
          if (!_disposed) {
            error = failure.toString();
            _wanted = false;
            _resumeTimer?.cancel();
            status = NarrationStatus.buffering;
            changed();
          }
        }),
      );
    });
  }

  /// Injectable network, playback and disk boundaries keep tests offline.
  final NarrationApi api;

  /// Single native handler, retained independently of reader routes.
  final NarrationPlayer player;

  /// Atomic sidecars and LRU cache.
  final NarrationStore store;

  /// Catalog membership fences operations whose book snapshot became deleted.
  final bool Function(CatalogBook) isBookAvailable;

  /// Authoritative global preferences, read when a publication is attached.
  final ReaderSettings Function() preferences;

  /// Existing normalized document loader, shared by rendering and indexing.
  final TextDocumentStore documents;

  /// Shared controller notification; the session creates no second UI controller.
  final void Function() changed;

  /// Complete text anchor and normalized progress are persisted together.
  final Future<void> Function(CatalogBook, TextPosition, double) commit;

  /// Latest catalog anchor, used to invalidate offsets after manual navigation.
  final TextPosition? Function(CatalogBook) currentPosition;

  /// Durable privacy receipt for a registration returning after deletion/switch.
  final Future<void> Function(String)? abandonRegistration;

  /// Mounted reader's awaitable, silent restoration boundary; library playback
  /// has no attached viewport and must not wait for a reading route.
  Future<void> Function(CatalogBook, TextPosition)? restoreViewport;

  /// Current publication; returning to the library does not detach it.
  CatalogBook? book;

  /// Opt-in and interrupted audio state for the current publication.
  NarrationManifest manifest = const NarrationManifest();

  /// Explicit buffering and playback state shown in the accessible controls.
  NarrationStatus status = NarrationStatus.idle;

  /// Recoverable service/cache failure; reading remains available.
  String? error;

  /// Most recently fetched monthly allowance, in UTF-16 input units.
  int? remaining;

  /// Immutable document metadata for chapter controls.
  TextDocument? document;
  TextSection? _section;
  List<NarrationChunk> _chunks = [];
  int _index = 0, _epoch = 0, _loadToken = 0;
  bool _wanted = false, _disposed = false, _seeked = false;
  late final StreamSubscription<int> _subscription;
  Future<void> _nativeTail = Future.value();
  Future<void>? _cacheMaintenance;
  Future<void> _preferenceUpdate = Future.value();
  final Map<String, Future<String>> _downloads = {};
  Timer? _resumeTimer;

  /// Listening owns progress while playing or waiting for the next chunk.
  bool ownsPosition(CatalogBook candidate) =>
      book?.hash == candidate.hash && _wanted;

  Future<T> _native<T>(Future<T> Function() action) {
    final result = _nativeTail.then((_) => action());
    _nativeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Opens the selected book, pausing another publication before loading it.
  Future<void> attach(CatalogBook target) async {
    if (_cacheMaintenance != null) await _cacheMaintenance;
    await _preferenceUpdate;
    if (_disposed || !isBookAvailable(target) || book?.hash == target.hash) {
      return;
    }
    await stop(restore: false);
    final epoch = ++_epoch;
    final loaded = await store.load(target);
    final doc = await documents.load(target.path);
    if (_disposed || epoch != _epoch || !isBookAvailable(target)) return;
    book = target;
    final settings = preferences();
    final sameVoice = loaded.voice == settings.narrationVoice;
    manifest = NarrationManifest(
      account: loaded.account,
      cloudBookId: loaded.cloudBookId,
      voice: settings.narrationVoice,
      speed: settings.narrationSpeed,
      anchor: loaded.anchor,
      chunkId: sameVoice ? loaded.chunkId : null,
      offsetMs: sameVoice ? loaded.offsetMs : 0,
    );
    document = doc;
    status = NarrationStatus.paused;
    changed();
  }

  /// Consent precedes Google sign-in and cloud book registration.
  Future<void> consent(CatalogBook target) async {
    await attach(target);
    final epoch = _epoch;
    final registration = await api.register(target);
    if (_disposed || epoch != _epoch || book?.hash != target.hash) {
      if (abandonRegistration != null) {
        await abandonRegistration!(registration.bookId);
      } else {
        await api.deleteBook(registration.bookId);
      }
      return;
    }
    manifest = NarrationManifest(
      account: registration.account,
      cloudBookId: registration.bookId,
      voice: manifest.voice,
      speed: manifest.speed,
    );
    remaining = registration.remaining;
    await store.save(target, manifest);
    changed();
  }

  Future<void> _prepare(int epoch) async {
    final target = book!;
    final position = currentPosition(target);
    final resume =
        manifest.anchor != null &&
        manifest.anchor == position &&
        manifest.chunkId != null;
    final anchor = resume ? manifest.anchor : position;
    final doc = document!;
    final ordinal = doc.sections.indexWhere(
      (section) => section.id == anchor?.sectionId,
    );
    final loadedSection = await documents.loadSection(
      target.path,
      doc.sections[ordinal < 0 ? 0 : ordinal].id,
    );
    if (!_current(epoch)) return;
    _section = loadedSection;
    _chunks = narrationChunks(_section!, from: anchor);
    _index = 0;
    if (!resume || _chunks.firstOrNull?.id != manifest.chunkId) {
      manifest = NarrationManifest(
        account: manifest.account,
        cloudBookId: manifest.cloudBookId,
        voice: manifest.voice,
        speed: manifest.speed,
        anchor: _chunks.firstOrNull?.start ?? anchor,
      );
    }
  }

  /// Starts at the committed anchor, reusing private cached files offline.
  Future<void> play() async {
    if (_cacheMaintenance != null) await _cacheMaintenance;
    await _preferenceUpdate;
    if (_wanted || book == null || manifest.cloudBookId == null || _disposed) {
      return;
    }
    _wanted = true;
    _seeked = false;
    error = null;
    status = NarrationStatus.buffering;
    final epoch = ++_epoch;
    changed();
    try {
      await _prepare(epoch);
      if (epoch != _epoch || !_wanted) return;
      await _start(epoch);
    } on Object catch (failure) {
      if (epoch == _epoch) {
        error = failure.toString();
        _wanted = false;
        status = NarrationStatus.buffering;
        changed();
      }
    }
  }

  bool _current(int epoch) => !_disposed && _wanted && epoch == _epoch;

  Future<String> _file(NarrationChunk chunk, int epoch) async {
    final target = book!;
    final profile = manifest;
    final key = narrationCacheKey(target, profile, chunk);
    final cached = await store.cached(target, key);
    if (cached != null) return cached;
    if (!_current(epoch)) throw StateError('Session changed.');
    return _downloads
        .putIfAbsent(key, () async {
          final bytes = await api.audio(
            profile.cloudBookId!,
            chunk,
            profile.voice,
            isCurrent: () => _current(epoch),
          );
          if (!_current(epoch)) throw StateError('Session changed.');
          return store.put(target, key, bytes);
        })
        .whenComplete(() => _downloads.remove(key));
  }

  Future<void> _start(int epoch) async {
    while (_index >= _chunks.length) {
      final ordinal =
          document!.sections.indexWhere(
            (summary) => summary.id == _section!.id,
          ) +
          1;
      if (ordinal >= document!.sections.length) {
        _wanted = false;
        _resumeTimer?.cancel();
        status = NarrationStatus.complete;
        store.pin({});
        changed();
        return;
      }
      final section = await documents.loadSection(
        book!.path,
        document!.sections[ordinal].id,
      );
      if (!_current(epoch)) return;
      _section = section;
      _chunks = narrationChunks(section);
      _index = 0;
    }
    final chunk = _chunks[_index];
    store.pin(
      _chunks
          .skip(_index)
          .take(3)
          .map((item) => narrationCacheKey(book!, manifest, item))
          .toSet(),
    );
    status = NarrationStatus.buffering;
    changed();
    final path = await _file(chunk, epoch);
    if (!_current(epoch)) return;
    final offset = manifest.chunkId == chunk.id
        ? Duration(milliseconds: manifest.offsetMs)
        : Duration.zero;
    final token = ++_loadToken;
    await _native(() async {
      if (!_current(epoch)) return;
      await player.load(path, book!.title, token, offset);
      if (!_current(epoch)) return;
      await player.speed(manifest.speed);
      status = NarrationStatus.playing;
      await player.resume();
    });
    if (!_current(epoch) ||
        token != _loadToken ||
        status != NarrationStatus.playing) {
      return;
    }
    manifest = NarrationManifest(
      account: manifest.account,
      cloudBookId: manifest.cloudBookId,
      voice: manifest.voice,
      speed: manifest.speed,
      anchor: currentPosition(book!) ?? chunk.start,
      chunkId: chunk.id,
      offsetMs: offset.inMilliseconds,
    );
    status = NarrationStatus.playing;
    _resumeTimer?.cancel();
    _resumeTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(flush().catchError((Object _) {}));
    });
    changed();
    // Sequential prefetch bounds provider work; pause fences the next request.
    unawaited(() async {
      for (final next in _chunks.skip(_index + 1).take(2).toList()) {
        if (!_current(epoch)) return;
        try {
          await _file(next, epoch);
        } on Object {
          return;
        }
      }
    }());
  }

  Future<void> _finished(int token) async {
    if (!_wanted || token != _loadToken || status != NarrationStatus.playing) {
      return;
    }
    final epoch = _epoch;
    // Seeking, including seeking near EOF then playing its tail, cannot prove
    // that this whole passage was heard. Replay from its anchor to commit it.
    if (_seeked) {
      await pause();
      return;
    }
    _resumeTimer?.cancel();
    status = NarrationStatus.buffering;
    final chunk = _chunks[_index];
    final target = book!;
    await commit(target, chunk.end, document!.progress(_section!, chunk.end));
    if (!_current(epoch)) return;
    manifest = NarrationManifest(
      account: manifest.account,
      cloudBookId: manifest.cloudBookId,
      voice: manifest.voice,
      speed: manifest.speed,
      anchor: chunk.end,
    );
    await store.save(target, manifest);
    if (!_current(epoch)) return;
    _index++;
    try {
      await _start(epoch);
    } on Object catch (failure) {
      if (_current(epoch)) {
        error = failure.toString();
        _wanted = false;
        status = NarrationStatus.buffering;
        changed();
      }
    }
  }

  /// Saves offset without advancing prose; called on suspension and periodically.
  Future<void> flush() async {
    if (_disposed) return;
    if (_cacheMaintenance != null) await _cacheMaintenance;
    await _flush();
  }

  Future<void> _flush() async {
    if (book == null || manifest.cloudBookId == null || _disposed) return;
    final value = NarrationManifest(
      account: manifest.account,
      cloudBookId: manifest.cloudBookId,
      voice: manifest.voice,
      speed: manifest.speed,
      anchor: manifest.anchor,
      chunkId: _seeked ? null : manifest.chunkId,
      offsetMs: _seeked || manifest.chunkId == null
          ? 0
          : player.position.inMilliseconds,
    );
    manifest = value;
    await store.save(book!, value);
  }

  /// Pauses generation and native audio, retaining a conservative resume anchor.
  Future<void> pause({bool restore = true}) async {
    if (_cacheMaintenance != null) await _cacheMaintenance;
    await _pause(restore: restore);
  }

  Future<void> _pause({bool restore = true}) async {
    _wanted = false;
    final epoch = ++_epoch;
    ++_loadToken;
    _resumeTimer?.cancel();
    await _native(player.pauseAudio);
    await _flush();
    if (epoch != _epoch) return;
    if (book != null) status = NarrationStatus.paused;
    changed();
    final target = book;
    final anchor = target == null ? null : currentPosition(target);
    if (restore && target != null && anchor != null) {
      await restoreViewport?.call(target, anchor);
    }
  }

  /// Stops and releases audio but keeps consent and interrupted playback on disk.
  Future<void> stop({bool restore = true}) async {
    if (_cacheMaintenance != null) await _cacheMaintenance;
    await _stop(restore: restore);
  }

  Future<void> _stop({bool restore = true}) async {
    await _pause(restore: false);
    final epoch = _epoch;
    // Release audio/media ownership before waiting for a viewport frame. A
    // lock-screen Stop must still complete its native work while UI is suspended.
    await _native(player.stopAudio);
    store.pin({});
    final target = book;
    final anchor = target == null ? null : currentPosition(target);
    if (restore && epoch == _epoch && target != null && anchor != null) {
      await restoreViewport?.call(target, anchor);
    }
  }

  /// Manual reader navigation invalidates offsets before it can write progress.
  Future<void> navigate(CatalogBook target) async {
    if (_cacheMaintenance != null) await _cacheMaintenance;
    if (book?.hash != target.hash) return;
    if (manifest.chunkId == null && !_wanted) return;
    await pause(restore: false);
    manifest = NarrationManifest(
      account: manifest.account,
      cloudBookId: manifest.cloudBookId,
      voice: manifest.voice,
      speed: manifest.speed,
    );
    await store.save(target, manifest);
  }

  /// Audio seeking is local and never grants text completion or illustration gates.
  Future<void> seek(Duration offset) async {
    if (_cacheMaintenance != null) await _cacheMaintenance;
    _seeked = true;
    final max = player.duration?.inMilliseconds ?? 0;
    await _native(
      () => player.seekAudio(
        Duration(
          milliseconds: offset.inMilliseconds.clamp(0, max > 0 ? max - 1 : 0),
        ),
      ),
    );
    await flush();
  }

  /// Applies global preferences without requesting audio or advancing progress.
  Future<void> applyPreferences(ReaderSettings settings) =>
      configure(voice: settings.narrationVoice, speed: settings.narrationSpeed);

  /// Updates playback identity; callers persist preferences globally.
  /// Voice switches pause at the committed anchor; speed reuses existing audio.
  Future<void> configure({String? voice, double? speed}) {
    if (voice != null && !['marin', 'cedar'].contains(voice)) {
      throw ArgumentError.value(voice);
    }
    if (speed != null && (!speed.isFinite || speed < .75 || speed > 2)) {
      throw ArgumentError.value(speed);
    }
    // Capture the current gate before queueing. A later cache clear waits for
    // this preference operation rather than making it wait on the newer gate.
    final maintenance = _cacheMaintenance;
    final operation = _preferenceUpdate.then(
      (_) => _configure(voice, speed, maintenance),
    );
    _preferenceUpdate = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _configure(
    String? voice,
    double? speed,
    Future<void>? maintenance,
  ) async {
    if (maintenance != null) await maintenance;
    if (_disposed) return;
    final voiceChanged = voice != null && voice != manifest.voice;
    final speedChanged = speed != null && speed != manifest.speed;
    // Typography and theme edits must not touch the audio handler or sidecar.
    if (!voiceChanged && !speedChanged) return;
    if (voiceChanged && book != null) await _stop();
    manifest = NarrationManifest(
      account: manifest.account,
      cloudBookId: manifest.cloudBookId,
      voice: voice ?? manifest.voice,
      speed: speed ?? manifest.speed,
      anchor: voiceChanged && book != null
          ? currentPosition(book!) ?? manifest.anchor
          : manifest.anchor,
      chunkId: voiceChanged ? null : manifest.chunkId,
      offsetMs: voiceChanged ? 0 : manifest.offsetMs,
    );
    await _native(() => player.speed(manifest.speed));
    if (book != null) await store.save(book!, manifest);
    changed();
  }

  /// Fences callbacks before deletion; waits for atomic writes before removing files.
  Future<void> detach(CatalogBook target) async {
    if (_cacheMaintenance != null) await _cacheMaintenance;
    if (book?.hash != target.hash) return;
    await stop(restore: false);
    await Future.wait(
      _downloads.values.map(
        (future) =>
            future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    );
    book = null;
    document = null;
    status = NarrationStatus.idle;
    changed();
  }

  /// Clears selected audio while retaining the open sheet's consent and book.
  /// The old audio offset is invalid after removing its exact cached generation.
  Future<void> clear() async {
    final target = book;
    if (target != null) await clearAllCache([target]);
  }

  /// Sums validated audio bytes without loading documents or changing LRU order.
  Future<int> cachedBytes(List<CatalogBook> books) async {
    var total = 0;
    for (final target in books) {
      if (!isBookAvailable(target)) continue;
      try {
        total += await store.cachedBytes(target);
      } on FormatException {
        if (isBookAvailable(target)) rethrow;
      }
    }
    return total;
  }

  /// Stops playback and drains fenced downloads before clearing all owned audio.
  /// Consent, cache identity metadata and complete text anchors are retained.
  Future<void> clearAllCache(List<CatalogBook> books) async {
    final previous = _cacheMaintenance;
    final preferences = _preferenceUpdate;
    final finished = Completer<void>();
    _cacheMaintenance = finished.future;
    try {
      if (previous != null) await previous;
      await preferences;
      if (_disposed) return;
      await _stop();
      await Future.wait(
        _downloads.values.map(
          (future) =>
              future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        ),
      );
      // All public playback mutations wait for maintenance. Private stop/flush
      // avoid reentering its gate while downloads are fenced and drained.
      for (final target in books) {
        if (_disposed || !isBookAvailable(target)) continue;
        try {
          final old = book?.hash == target.hash
              ? manifest
              : await store.load(target);
          if (_disposed || !isBookAvailable(target)) continue;
          final cleared = NarrationManifest(
            account: old.account,
            cloudBookId: old.cloudBookId,
            voice: old.voice,
            speed: old.speed,
            anchor: currentPosition(target) ?? old.anchor,
          );
          await store.save(target, cleared);
          if (!isBookAvailable(target)) continue;
          await store.clear(target);
          if (book?.hash == target.hash) manifest = cleared;
        } on FormatException {
          // An older delete may finish after the snapshot was taken. Owned-path
          // rejection is safe to ignore only once the catalog confirms removal.
          if (isBookAvailable(target)) rethrow;
        }
      }
      if (!_disposed) changed();
    } finally {
      finished.complete();
      if (identical(_cacheMaintenance, finished.future)) {
        _cacheMaintenance = null;
      }
    }
  }

  /// Releases session playback and callbacks; shutdown persistence is awaited separately.
  Future<void> dispose() async {
    if (_cacheMaintenance != null) await _cacheMaintenance;
    await stop(restore: false);
    _disposed = true;
    await _subscription.cancel();
    await player.dispose();
  }
}
