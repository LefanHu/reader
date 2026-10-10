import 'dart:typed_data';

import '../catalog/catalog_book.dart';
import 'narration_manifest.dart';

/// Atomic app-owned narration sidecars and a bounded, pinned local audio cache.
abstract interface class NarrationStore {
  /// Recovers committed, temporary, then backup manifests for older catalogs.
  Future<NarrationManifest> load(CatalogBook book);

  /// Serializes complete consent and resume state; never changes the catalog.
  Future<void> save(CatalogBook book, NarrationManifest manifest);

  /// Returns a validated local audio path and refreshes its LRU use time.
  Future<String?> cached(CatalogBook book, String key);

  /// Publishes flushed audio atomically before enforcing the global LRU budget.
  Future<String> put(CatalogBook book, String key, Uint8List bytes);

  /// Active and buffered files cannot be evicted while the player owns them.
  void pin(Set<String> keys);

  /// Counts validated owned WAV files without refreshing their LRU timestamps.
  Future<int> cachedBytes(CatalogBook book);

  /// Removes only audio; consent and reading position survive cache clearing.
  Future<void> clear(CatalogBook book);
}
