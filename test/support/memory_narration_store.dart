// Fake boundary behavior is documented at each owning type.
// ignore_for_file: public_member_api_docs
import 'dart:async';
import 'dart:typed_data';

import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/narration/narration_manifest.dart';
import 'package:reader/narration/store.dart';

import '../fixtures/narration_audio.dart';

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
