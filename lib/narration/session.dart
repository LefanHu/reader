import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;

import '../catalog/catalog_book.dart';
import '../serial_queue.dart';
import '../preferences/reader_settings.dart';
import '../text/document.dart';
import '../text/document_store.dart';
import '../text/text_position.dart';
import '../text/text_section.dart';
import '../text/narration_chunk.dart';
import '../text/narration_playback_unit.dart';
import '../text/narration_range.dart';
import 'api.dart';
import 'narration_manifest.dart';
import 'player.dart';
import 'narration_cache_key.dart';
import 'store.dart';
import 'source.dart';
import 'narration_audio_asset.dart';
import 'narration_highlight_tracker.dart';

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
  /// [highlightChanged] publishes cue-boundary highlight moves, which happen
  /// at every spoken word, apart from [changed]; it defaults to [changed].
  NarrationSession({
    required this.api,
    required this.source,
    required this.player,
    required this.store,
    required this.changed,
    required this.commit,
    required this.currentPosition,
    void Function()? highlightChanged,
    TextDocumentStore? documents,
    this.abandonRegistration,
    ReaderSettings Function()? preferences,
    bool Function(CatalogBook)? isBookAvailable,
  }) : isBookAvailable = isBookAvailable ?? ((_) => true),
       preferences = preferences ?? (() => const ReaderSettings()),
       documents = documents ?? TextDocumentStore() {
    player.bind(play: play, pause: pause, stop: stop, seek: seek);
    _highlight = NarrationHighlightTracker(
      player: player,
      changed: highlightChanged ?? changed,
    );
    _subscription = player.completed.listen((token) {
      unawaited(
        _finished(token).catchError((Object failure) {
          if (!_disposed) _fail(failure);
        }),
      );
    });
  }

  /// Injectable network, playback and disk boundaries keep tests offline.
  final NarrationApi api;

  /// Explicit synthesis boundary: local speech never crosses the cloud API.
  final NarrationSource source;

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

  /// Registration and interrupted audio state for the current publication.
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
  List<NarrationPlaybackUnit> _units = [];
  NarrationChunk? _activeChunk;
  int _index = 0, _epoch = 0, _loadToken = 0;
  bool _wanted = false, _disposed = false, _seeked = false;
  late final StreamSubscription<int> _subscription;
  final _nativeQueue = SerialQueue();
  Future<void>? _cacheMaintenance;
  final _preferenceQueue = SerialQueue();
  final Map<String, Future<NarrationAudioAsset>> _downloads = {};
  late final NarrationHighlightTracker _highlight;
  Timer? _resumeTimer;

  /// Listening owns progress while playing or waiting for the next chunk.
  bool ownsPosition(CatalogBook candidate) =>
      book?.hash == candidate.hash && _wanted;

  /// Exact prepared playback or buffering target, never the previous manifest
  /// chunk. Chunks stay within one normalized block, so its start identifies the
  /// active paragraph without word timing. Unprepared/paused sessions return null.
  NarrationChunk? get activeChunk =>
      status == NarrationStatus.playing || status == NarrationStatus.buffering
      ? _activeChunk
      : null;

  /// Local readiness has no account, registration, or deletion-outbox gate.
  bool get ready =>
      book != null &&
      (!source.requiresCloudRegistration || manifest.cloudBookId != null);

  /// Playback-aligned decoration is presentation only, never reading progress.
  NarrationRange? get activeHighlight =>
      status == NarrationStatus.playing ? _highlight.range : null;

  /// Native bounds follow their current start; sentence fallback follows the
  /// actual clip so a later subclip cannot jump back to an overlong sentence.
  TextPosition? get activeFollowPosition => status != NarrationStatus.playing
      ? null
      : _highlight.hasNativeTiming
      ? activeHighlight?.start ?? activeChunk?.start
      : activeChunk?.start;

  /// Only the mounted reader may schedule cue-boundary updates.
  void attachHighlightOwner(Object owner) => _highlight.attach(owner);

  /// An obsolete route cannot detach a replacement reader's highlight owner.
  void detachHighlightOwner(Object owner) => _highlight.detach(owner);

  /// Opens the selected book, pausing another publication before loading it.
  Future<void> attach(CatalogBook target) async {
    if (_cacheMaintenance != null) await _cacheMaintenance;
    await _preferenceQueue.idle;
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
    manifest = loaded.withProfile(
      voice: settings.narrationVoice,
      speed: settings.narrationSpeed,
      engine: source.engine,
      synthesisFingerprint: source.synthesisFingerprint,
      segmentationPolicy: source.segmentationPolicy,
      anchor: loaded.anchor,
    );
    document = doc;
    // Commit converted identity before any replacement clip is rendered.
    await store.save(target, manifest);
    if (_disposed ||
        epoch != _epoch ||
        book?.hash != target.hash ||
        !isBookAvailable(target)) {
      return;
    }
    status = NarrationStatus.paused;
    changed();
  }

  /// Registers an available book through the authenticated cloud boundary.
  Future<void> register(CatalogBook target) async {
    await attach(target);
    if (!source.requiresCloudRegistration) return;
    if (_disposed ||
        !isBookAvailable(target) ||
        book?.hash != target.hash ||
        manifest.cloudBookId != null) {
      return;
    }
    final epoch = _epoch;
    final registration = await api.register(target);
    if (_disposed ||
        epoch != _epoch ||
        book?.hash != target.hash ||
        !isBookAvailable(target)) {
      if (abandonRegistration != null) {
        await abandonRegistration!(registration.bookId);
      } else {
        await api.deleteBook(registration.bookId);
      }
      return;
    }
    manifest = manifest.withRegistration(
      account: registration.account,
      cloudBookId: registration.bookId,
      anchor: currentPosition(target),
    );
    remaining = registration.remaining;
    await store.save(target, manifest);
    changed();
  }

  Future<void> _prepare(int epoch, {TextPosition? start}) async {
    final target = book!;
    final position = currentPosition(target);
    final samePosition = manifest.anchor == position;
    final resume = start == null && samePosition && manifest.chunkId != null;
    final anchor =
        start ??
        (samePosition ? manifest.chunkStart ?? manifest.anchor : position);
    final doc = document!;
    final ordinal = doc.ordinalOf(anchor?.sectionId);
    if (start != null && ordinal < 0) {
      throw ArgumentError.value(start, 'start', 'Unknown narration section.');
    }
    final loadedSection = await documents.loadSection(
      target.path,
      doc.sections[ordinal < 0 ? 0 : ordinal].id,
    );
    if (!_current(epoch)) return;
    if (start != null && loadedSection.resolve(start) != start) {
      throw ArgumentError.value(start, 'start', 'Invalid narration anchor.');
    }
    _section = loadedSection;
    final units = await source.units(
      loadedSection,
      from: anchor,
      language: doc.language,
    );
    if (!_current(epoch)) return;
    _units = units;
    _index = 0;
    if (!resume || _units.firstOrNull?.chunk.id != manifest.chunkId) {
      manifest = manifest.withPlayback(
        anchor: position,
        chunkStart: _units.firstOrNull?.chunk.start ?? anchor,
      );
    }
  }

  /// Starts at the committed anchor, reusing private cached files offline.
  Future<void> play() => _play();

  /// Replaces prior playback with an exact logical start, never a catalog write.
  /// Its separate chunk anchor supports pause, restart and offline cached replay.
  Future<void> playFrom(TextPosition start) => _play(start: start);

  Future<void> _play({TextPosition? start}) async {
    if (_cacheMaintenance != null) await _cacheMaintenance;
    await _preferenceQueue.idle;
    if (book == null || !ready || _disposed || (_wanted && start == null)) {
      return;
    }
    final oldEpoch = _epoch;
    final epoch = ++_epoch;
    // Fence old completion synchronously, before native cancellation can yield.
    ++_loadToken;
    _wanted = false;
    _resumeTimer?.cancel();
    _highlight.clear();
    await source.cancel(oldEpoch);
    if (_disposed || epoch != _epoch) return;
    _wanted = true;
    _seeked = false;
    // A replacement must not present the previous book/paragraph while its
    // section is loading. The exact buffering target appears once prepared.
    _activeChunk = null;
    error = null;
    status = NarrationStatus.buffering;
    if (start != null) {
      manifest = manifest.withPlayback(
        anchor: currentPosition(book!),
        chunkStart: start,
      );
    }
    changed();
    try {
      if (start != null) {
        await _nativeQueue.run(() async {
          if (_current(epoch)) await player.stopAudio();
        });
        if (!_current(epoch)) return;
        store.pin({});
      }
      await _prepare(epoch, start: start);
      if (!_current(epoch)) return;
      await store.save(book!, manifest);
      if (!_current(epoch)) return;
      await _start(epoch);
    } on Object catch (failure) {
      if (epoch == _epoch) _fail(failure);
    }
  }

  bool _current(int epoch) => !_disposed && _wanted && epoch == _epoch;

  /// Recoverable failure: stops wanting playback and shows the message.
  void _fail(Object failure) {
    error = switch (failure) {
      StateError(:final message) => message,
      FormatException(:final message) => message,
      // Native narration codes carry a user-readable cause in `message`.
      PlatformException(:final message) when message != null => message,
      _ => failure.toString(),
    };
    _wanted = false;
    _resumeTimer?.cancel();
    status = NarrationStatus.buffering;
    changed();
  }

  Future<NarrationAudioAsset> _file(
    NarrationPlaybackUnit unit,
    int epoch,
  ) async {
    final target = book!;
    final profile = manifest;
    final key = narrationCacheKey(
      target,
      profile,
      unit.chunk,
      sentence: unit.sentence,
    );
    final cached = await store.cached(target, key);
    if (cached != null) return cached;
    if (!_current(epoch)) throw const NarrationCancelled();
    // Single-flight is generation-scoped: cancelled work cannot poison retry.
    final download = '$epoch:$key';
    return _downloads
        .putIfAbsent(
          download,
          () => source.render(
            target,
            profile,
            unit,
            store,
            generation: epoch,
            isCurrent: () => _current(epoch) && isBookAvailable(target),
          ),
        )
        .whenComplete(() => _downloads.remove(download));
  }

  Future<void> _start(int epoch) async {
    while (_index >= _units.length) {
      final ordinal = document!.ordinalOf(_section!.id) + 1;
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
      final units = await source.units(section, language: document!.language);
      if (!_current(epoch)) return;
      _units = units;
      _index = 0;
    }
    final unit = _units[_index];
    final chunk = unit.chunk;
    _activeChunk = chunk;
    store.pin(
      _units
          .skip(_index)
          .take(3)
          .map(
            (item) => narrationCacheKey(
              book!,
              manifest,
              item.chunk,
              sentence: item.sentence,
            ),
          )
          .toSet(),
    );
    status = NarrationStatus.buffering;
    changed();
    final asset = await _file(unit, epoch);
    if (!_current(epoch)) return;
    final offset = manifest.chunkId == chunk.id
        ? Duration(milliseconds: manifest.offsetMs)
        : Duration.zero;
    final token = ++_loadToken;
    await _nativeQueue.run(() async {
      if (!_current(epoch)) return;
      await player.load(asset.path, book!.title, token, offset);
      if (!_current(epoch)) return;
      await player.speed(manifest.speed);
      final timing = asset.timing;
      _highlight.load(
        token: token,
        unit: unit,
        timing:
            timing != null &&
                player.duration != null &&
                timing.matches(
                  audioKey: narrationCacheKey(
                    book!,
                    manifest,
                    chunk,
                    sentence: unit.sentence,
                  ),
                  chunkId: chunk.id,
                  sourceDigest: chunk.digest,
                  synthesisFingerprint: source.synthesisFingerprint,
                  duration: player.duration,
                )
            ? timing
            : null,
      );
      status = NarrationStatus.playing;
      await player.resume();
    });
    if (!_current(epoch) ||
        token != _loadToken ||
        status != NarrationStatus.playing) {
      return;
    }
    manifest = manifest.withPlayback(
      anchor: currentPosition(book!),
      chunkId: chunk.id,
      chunkStart: chunk.start,
      offsetMs: offset.inMilliseconds,
    );
    status = NarrationStatus.playing;
    _resumeTimer?.cancel();
    // Pause, suspension and exit flush exactly; this periodic write only
    // bounds lost offset after a crash, so it need not run every few seconds.
    _resumeTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(flush().catchError((Object _) {}));
    });
    changed();
    // Sequential prefetch bounds provider work; pause fences the next request.
    unawaited(() async {
      for (final next in _units.skip(_index + 1).take(2).toList()) {
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
    _activeChunk = null;
    _highlight.clear();
    status = NarrationStatus.buffering;
    final chunk = _units[_index].chunk;
    final target = book!;
    await commit(target, chunk.end, document!.progress(_section!, chunk.end));
    if (!_current(epoch)) return;
    manifest = manifest.withoutPlayback(anchor: chunk.end);
    await store.save(target, manifest);
    if (!_current(epoch)) return;
    _index++;
    try {
      await _start(epoch);
    } on Object catch (failure) {
      if (_current(epoch)) _fail(failure);
    }
  }

  /// Saves offset without advancing prose; called on suspension and periodically.
  Future<void> flush() async {
    if (_disposed) return;
    if (_cacheMaintenance != null) await _cacheMaintenance;
    await _flush();
  }

  Future<void> _flush() async {
    if (!ready || _disposed) return;
    final value = manifest.withPlayback(
      anchor: manifest.anchor,
      chunkId: _seeked ? null : manifest.chunkId,
      chunkStart: _seeked ? null : manifest.chunkStart,
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
    final oldEpoch = _epoch;
    final epoch = ++_epoch;
    await source.cancel(oldEpoch);
    ++_loadToken;
    _resumeTimer?.cancel();
    await _nativeQueue.run(player.pauseAudio);
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

  /// Stops and releases audio but keeps registration and interrupted playback.
  Future<void> stop({bool restore = true}) async {
    if (_cacheMaintenance != null) await _cacheMaintenance;
    await _stop(restore: restore);
  }

  Future<void> _stop({bool restore = true}) async {
    await _pause(restore: false);
    final epoch = _epoch;
    // Release audio/media ownership before waiting for a viewport frame. A
    // lock-screen Stop must still complete its native work while UI is suspended.
    await _nativeQueue.run(player.stopAudio);
    _highlight.clear();
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
    manifest = manifest.withoutPlayback();
    await store.save(target, manifest);
  }

  /// Audio seeking is local and never grants text completion or illustration gates.
  Future<void> seek(Duration offset) async {
    if (_cacheMaintenance != null) await _cacheMaintenance;
    _seeked = true;
    final max = player.duration?.inMilliseconds ?? 0;
    await _nativeQueue.run(
      () => player.seekAudio(
        Duration(
          milliseconds: offset.inMilliseconds.clamp(0, max > 0 ? max - 1 : 0),
        ),
      ),
    );
    await flush();
  }

  /// Seeking is meaningful only for a prepared chunk of a ready publication.
  bool get canSeek => ready && manifest.chunkId != null;

  /// Relative seek from the current native position; clamped like [seek].
  Future<void> seekBy(Duration delta) => seek(player.position + delta);

  /// Refreshes the cloud allowance shown in the sheet; local speech has none.
  Future<void> refreshAllowance() async {
    final target = book;
    if (target == null || !source.requiresCloudRegistration) return;
    final config = await api.configuration();
    if (_disposed || book?.hash != target.hash) return;
    remaining = config['remaining'] as int?;
    changed();
  }

  /// Applies restored/global settings, retaining unavailable saved voice identity.
  /// The preference owner validates new selections; unrelated edits remain valid.
  Future<void> applyPreferences(ReaderSettings settings) =>
      _queuePreferences(settings.narrationVoice, settings.narrationSpeed);

  /// Updates playback identity; callers persist preferences globally.
  /// Voice switches pause at the committed anchor; speed reuses existing audio.
  Future<void> configure({String? voice, double? speed}) {
    if (voice != null &&
        voice != manifest.voice &&
        !source.voices.any((candidate) => candidate.identifier == voice)) {
      throw ArgumentError.value(voice, 'voice', 'Voice is not installed.');
    }
    if (speed != null && (!speed.isFinite || speed < .75 || speed > 2)) {
      throw ArgumentError.value(speed);
    }
    return _queuePreferences(voice, speed);
  }

  Future<void> _queuePreferences(String? voice, double? speed) {
    // Capture the current gate before queueing. A later cache clear waits for
    // this preference operation rather than making it wait on the newer gate.
    final maintenance = _cacheMaintenance;
    return _preferenceQueue.run(() => _configure(voice, speed, maintenance));
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
    manifest = manifest.withProfile(
      voice: voice ?? manifest.voice,
      speed: speed ?? manifest.speed,
      engine: manifest.engine,
      synthesisFingerprint: manifest.synthesisFingerprint,
      segmentationPolicy: manifest.segmentationPolicy,
      anchor: voiceChanged && book != null
          ? currentPosition(book!) ?? manifest.anchor
          : manifest.anchor,
    );
    await _nativeQueue.run(() => player.speed(manifest.speed));
    if (book != null) await store.save(book!, manifest);
    changed();
  }

  /// Fences callbacks before deletion; waits for atomic writes before removing files.
  Future<void> detach(CatalogBook target) async {
    if (_cacheMaintenance != null) await _cacheMaintenance;
    if (book?.hash != target.hash) return;
    await stop(restore: false);
    final epoch = _epoch;
    await Future.wait(
      _downloads.values.map(
        (future) =>
            future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    );
    if (_disposed || epoch != _epoch || book?.hash != target.hash) return;
    book = null;
    document = null;
    status = NarrationStatus.idle;
    changed();
  }

  /// Clears selected audio while retaining the open sheet's registration and book.
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
  /// Registration, cache identity metadata and complete text anchors are retained.
  Future<void> clearAllCache(List<CatalogBook> books) =>
      _clearAudio(books, forgetRegistration: false);

  /// Clears audio after successful server deletion; keeps complete text anchors
  /// and synthesis identity.
  Future<void> forgetCloudAccount(List<CatalogBook> books) =>
      _clearAudio(books, forgetRegistration: true);

  Future<void> _clearAudio(
    List<CatalogBook> books, {
    required bool forgetRegistration,
  }) async {
    final previous = _cacheMaintenance;
    final preferences = _preferenceQueue.idle;
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
          final anchor = currentPosition(target) ?? old.anchor;
          final cleared = forgetRegistration
              ? old.withoutRegistration(anchor: anchor)
              : old.withoutPlayback(anchor: anchor);
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
      if (forgetRegistration) remaining = null;
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
    await _highlight.dispose();
    await player.dispose();
  }
}
