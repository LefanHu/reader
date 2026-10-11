// Fake boundary behavior is documented at each owning type.
// ignore_for_file: public_member_api_docs
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/narration/narration_audio_asset.dart';
import 'package:reader/narration/narration_manifest.dart';
import 'package:reader/narration/narration_timing.dart';
import 'package:reader/narration/narration_wav.dart';
import 'package:reader/narration/store.dart';

/// In-memory cloud cache with fixture-owned staging files for native writers.
///
/// Cloud paths remain fake-player paths. Callback generation uses actual private
/// temporary files, validates PCM WAV, and publishes only while its book epoch
/// is current. Every instance registers teardown before any directory is made.
class MemoryNarrationStore implements NarrationStore {
  MemoryNarrationStore() {
    addTearDown(dispose);
  }

  final manifests = <String, NarrationManifest>{};
  final files = <String, String>{};
  final timings = <String, NarrationTiming>{};
  final _sizes = <String, int>{};
  final _books = <String, Set<String>>{};
  final _epochs = <String, int>{};
  // Drop idle tails so teardown never awaits a completed fake-zone future.
  Future<void>? _tail;
  Future<Directory>? _fixtureRoot;
  bool _disposed = false;
  Set<String> pins = {};
  Completer<void>? clearGate;
  int saves = 0;

  Future<T> _serial<T>(Future<T> Function() action) {
    final previous = _tail;
    final result = previous == null
        ? Future<T>.sync(action)
        : previous.then((_) => action());
    late final Future<void> tail;
    void releaseTail() {
      if (identical(_tail, tail)) _tail = null;
    }

    tail = result.then<void>(
      (_) => releaseTail(),
      onError: (Object _, StackTrace _) => releaseTail(),
    );
    _tail = tail;
    return result;
  }

  @override
  Future<NarrationManifest> load(CatalogBook book) async =>
      manifests[book.hash] ?? const NarrationManifest();

  @override
  Future<void> save(CatalogBook book, NarrationManifest manifest) async {
    saves++;
    manifests[book.hash] = manifest;
  }

  @override
  Future<NarrationAudioAsset?> cached(CatalogBook book, String key) async {
    final path = files[key];
    if (path == null || !(_books[book.hash]?.contains(key) ?? false)) {
      return null;
    }
    return NarrationAudioAsset(path: path, timing: timings[key]);
  }

  @override
  Future<String> put(
    CatalogBook book,
    String key,
    Uint8List bytes, {
    bool Function()? isCurrent,
  }) async {
    final epoch = _epochs[book.hash] ?? 0;
    return _serial(() async {
      bool current() =>
          !_disposed &&
          (_epochs[book.hash] ?? 0) == epoch &&
          (isCurrent?.call() ?? true);
      if (!current()) throw StateError('Narration generation changed.');
      await _removePublished(key);
      if (!current()) throw StateError('Narration generation changed.');
      files[key] = '/cache/$key.wav';
      timings.remove(key);
      _sizes[key] = bytes.length;
      (_books[book.hash] ??= {}).add(key);
      return files[key]!;
    });
  }

  @override
  Future<NarrationAudioAsset> create(
    CatalogBook book,
    String key,
    Future<NarrationTiming?> Function(String stagingPath) writer, {
    required bool Function() isCurrent,
  }) {
    final epoch = _epochs[book.hash] ?? 0;
    return _serial(
      () => _create(book, key, writer, isCurrent: isCurrent, epoch: epoch),
    );
  }

  Future<NarrationAudioAsset> _create(
    CatalogBook book,
    String key,
    Future<NarrationTiming?> Function(String stagingPath) writer, {
    required bool Function() isCurrent,
    required int epoch,
  }) async {
    final validKey = RegExp(r'^[a-f0-9]{64}$');
    if (!validKey.hasMatch(key) || !validKey.hasMatch(book.hash)) {
      throw const FormatException('Invalid narration fixture identity.');
    }
    bool current() =>
        !_disposed && (_epochs[book.hash] ?? 0) == epoch && isCurrent();
    if (!current()) throw StateError('Narration generation changed.');
    final root = await (_fixtureRoot ??= Directory.systemTemp.createTemp(
      'reader_narration_writer_',
    ));
    if (!current()) throw StateError('Narration generation changed.');
    final directory = Directory('${root.path}/books/${book.hash}/narration');
    await directory.create(recursive: true);
    if (!current()) throw StateError('Narration generation changed.');
    final file = File('${directory.path}/$key.wav');
    final temporary = File('${file.path}.tmp');
    final companion = File('${directory.path}/$key.timing.json');
    final timingTemporary = File('${companion.path}.tmp');
    if (await FileSystemEntity.type(temporary.path, followLinks: false) !=
            FileSystemEntityType.notFound ||
        await FileSystemEntity.type(timingTemporary.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const FormatException('Narration staging target already exists.');
    }
    try {
      final generatedTiming = await writer(temporary.path);
      if (!current()) throw StateError('Narration generation changed.');
      final duration = await validateNarrationWav(temporary);
      var timing =
          generatedTiming != null &&
              validKey.hasMatch(generatedTiming.chunkId) &&
              validKey.hasMatch(generatedTiming.sourceDigest) &&
              generatedTiming.matches(audioKey: key, duration: duration)
          ? generatedTiming
          : null;
      if (timing != null) {
        if (FileSystemEntity.typeSync(
              timingTemporary.path,
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
          throw const FormatException('Unexpected narration timing target.');
        }
        try {
          final bytes = utf8.encode(jsonEncode(timing.toJson()));
          if (bytes.length > 2 * 1024 * 1024) {
            timing = null;
          } else {
            await timingTemporary.writeAsBytes(bytes, flush: true);
          }
        } on FileSystemException {
          timing = null;
        }
      }
      final audioBytes = await temporary.length();
      final timingBytes = timing == null ? 0 : await timingTemporary.length();
      if (!current()) throw StateError('Narration generation changed.');
      for (final target in [file, companion, temporary, timingTemporary]) {
        final kind = FileSystemEntity.typeSync(target.path, followLinks: false);
        if (kind != FileSystemEntityType.notFound &&
            kind != FileSystemEntityType.file) {
          throw const FormatException(
            'Unexpected narration publication target.',
          );
        }
      }
      if (companion.existsSync()) companion.deleteSync();
      temporary.renameSync(file.path);
      if (timing != null) {
        try {
          timingTemporary.renameSync(companion.path);
        } on FileSystemException {
          timing = null;
        }
      }
      files[key] = file.path;
      if (timing == null) {
        timings.remove(key);
      } else {
        timings[key] = timing;
      }
      _sizes[key] = audioBytes + (timing == null ? 0 : timingBytes);
      (_books[book.hash] ??= {}).add(key);
      return NarrationAudioAsset(path: file.path, timing: timing);
    } finally {
      for (final owned in [temporary, timingTemporary]) {
        if (await FileSystemEntity.type(owned.path, followLinks: false) ==
            FileSystemEntityType.file) {
          await owned.delete();
        }
      }
    }
  }

  @override
  void pin(Set<String> keys) {
    pins = Set.of(keys);
  }

  @override
  Future<int> cachedBytes(CatalogBook book) async => (_books[book.hash] ?? {})
      .fold<int>(0, (sum, key) => sum + (_sizes[key] ?? 0));

  Future<void> _removePublished(String key) async {
    final path = files[key];
    if (path == null || path.startsWith('/cache/')) return;
    for (final file in [
      File(path),
      File('${path.substring(0, path.length - 4)}.timing.json'),
    ]) {
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await file.delete();
      }
    }
  }

  @override
  Future<void> clear(CatalogBook book) async {
    _epochs[book.hash] = (_epochs[book.hash] ?? 0) + 1;
    await clearGate?.future;
    for (final key in _books.remove(book.hash) ?? <String>{}) {
      await _removePublished(key);
      files.remove(key);
      timings.remove(key);
      _sizes.remove(key);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final tail = _tail;
    if (tail != null) await tail;
    final root = await _fixtureRoot;
    if (root != null && await root.exists()) await root.delete(recursive: true);
    files.clear();
    timings.clear();
    _sizes.clear();
    _books.clear();
  }
}
