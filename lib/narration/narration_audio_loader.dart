import '../catalog/catalog_book.dart';
import '../text/narration_playback_unit.dart';
import 'narration_audio_asset.dart';
import 'narration_cache_key.dart';
import 'narration_manifest.dart';
import 'source.dart';
import 'store.dart';

/// Resolves playback units to private audio files: cached files first, then
/// one single-flight render per session generation and cache key.
///
/// Single-flight is generation-scoped (`'$generation:$key'`), so a cancelled
/// render cannot poison a retry under the next generation.
class NarrationAudioLoader {
  /// Renders through [source] into [store].
  NarrationAudioLoader({required this.source, required this.store});

  /// Synthesis boundary; local speech never crosses the cloud API.
  final NarrationSource source;

  /// Owned cache and its LRU.
  final NarrationStore store;

  final Map<String, Future<NarrationAudioAsset>> _inFlight = {};

  /// The cached or newly rendered audio for [unit] under [profile]. Throws
  /// [NarrationCancelled] instead of starting a render once [isCurrent] fails.
  Future<NarrationAudioAsset> load(
    CatalogBook book,
    NarrationManifest profile,
    NarrationPlaybackUnit unit, {
    required int generation,
    required bool Function() isCurrent,
  }) async {
    final key = narrationCacheKey(
      book,
      profile,
      unit.chunk,
      sentence: unit.sentence,
    );
    final cached = await store.cached(book, key);
    if (cached != null) return cached;
    if (!isCurrent()) throw const NarrationCancelled();
    final flight = '$generation:$key';
    return _inFlight
        .putIfAbsent(
          flight,
          () => source.render(
            book,
            profile,
            unit,
            store,
            generation: generation,
            isCurrent: isCurrent,
          ),
        )
        .whenComplete(() => _inFlight.remove(flight));
  }

  /// Completes once every in-flight render has settled, ignoring failures;
  /// deletion and cache clearing wait here before removing files.
  Future<void> drain() => Future.wait(
    _inFlight.values.map(
      (future) =>
          future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    ),
  );
}
