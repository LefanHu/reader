import 'dart:typed_data';

import '../catalog/catalog_book.dart';
import 'narration_audio_asset.dart';
import 'narration_manifest.dart';
import 'narration_timing.dart';

/// Atomic app-owned narration sidecars and a bounded, pinned local audio cache.
abstract interface class NarrationStore {
  /// Recovers committed, temporary, then backup manifests.
  Future<NarrationManifest> load(CatalogBook book);

  /// Serializes complete registration and resume state; never changes the catalog.
  Future<void> save(CatalogBook book, NarrationManifest manifest);

  /// Returns playable owned audio with optional validated presentation timing.
  ///
  /// Missing or corrupt timing is not a cache miss. This refreshes only the
  /// audio entry's LRU time, and never regenerates an otherwise playable WAV.
  Future<NarrationAudioAsset?> cached(CatalogBook book, String key);

  /// Publishes flushed audio atomically before enforcing the global LRU budget.
  /// A source supplies [isCurrent] to fence queued publication after cancellation.
  Future<String> put(
    CatalogBook book,
    String key,
    Uint8List bytes, {
    bool Function()? isCurrent,
  });

  /// Gives a writer an absent, private staging path and publishes its closed WAV.
  ///
  /// The writer must settle on cancellation and must not choose another path.
  /// Publication checks [isCurrent] and book ownership again after writing;
  /// failure removes only this operation's staging files. Optional timing must
  /// match the audio key and WAV duration or it is discarded, not the audio.
  Future<NarrationAudioAsset> create(
    CatalogBook book,
    String key,
    Future<NarrationTiming?> Function(String stagingPath) writer, {
    required bool Function() isCurrent,
  });

  /// Active and buffered files cannot be evicted while the player owns them.
  void pin(Set<String> keys);

  /// Counts owned WAV entries and their matching regular timing/staging files.
  Future<int> cachedBytes(CatalogBook book);

  /// Removes only audio; registration and reading position survive cache clearing.
  Future<void> clear(CatalogBook book);
}
