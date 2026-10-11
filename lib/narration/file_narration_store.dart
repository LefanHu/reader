import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../atomic_json_file.dart';
import '../catalog/catalog_book.dart';
import 'narration_audio_asset.dart';
import 'narration_manifest.dart';
import 'narration_timing.dart';
import 'narration_wav.dart';
import 'store.dart';

/// Filesystem implementation restricted to the content-addressed catalog root.
class FileNarrationStore implements NarrationStore {
  /// The catalog root is injected; cache eviction never follows symlinks.
  FileNarrationStore(this.root, {this.maxBytes = 250 * 1024 * 1024});

  /// Private catalog root, shared with imports and durable deletion requests.
  final Directory root;

  /// Global byte budget; active files may briefly exceed it until unpinned.
  final int maxBytes;
  static final _keyPattern = RegExp(r'^[a-f0-9]{64}$');
  static final _audioPattern = RegExp(r'/[a-f0-9]{64}\.wav$');
  static final _companionPattern = RegExp(
    r'/([a-f0-9]{64})\.(?:wav\.tmp|timing\.json(?:\.tmp)?)$',
  );
  static const _maxTimingBytes = 2 * 1024 * 1024;
  Set<String> _pins = {};
  static final _tails = <String, Future<void>>{};

  // Claims span native writer waits across all stores sharing the root. A
  // same-key successor waits outside _serial; clear invalidates every claimant.
  static final _writers = <String, List<_NarrationWrite>>{};

  Future<T> _serial<T>(Future<T> Function() action) {
    final key = root.absolute.path;
    final result = (_tails[key] ?? Future<void>.value()).then((_) => action());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tails[key] = tail;
    tail.whenComplete(() {
      if (identical(_tails[key], tail)) _tails.remove(key);
    });
    return result;
  }

  Directory _directory(CatalogBook book) {
    final parent = File(book.path).absolute.parent;
    final expected = '${root.absolute.path}/books/${book.hash}';
    if (!_keyPattern.hasMatch(book.hash) ||
        parent.path != expected ||
        FileSystemEntity.typeSync(root.absolute.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        FileSystemEntity.typeSync(
              '${root.absolute.path}/books',
              followLinks: false,
            ) !=
            FileSystemEntityType.directory ||
        FileSystemEntity.typeSync(parent.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        FileSystemEntity.typeSync(book.path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const FormatException('Narration path is outside owned storage.');
    }
    final directory = Directory('$expected/narration');
    final kind = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (kind != FileSystemEntityType.notFound &&
        kind != FileSystemEntityType.directory) {
      throw const FormatException('Narration storage cannot be a link.');
    }
    return directory;
  }

  File _ownedFile(String path, {bool absent = false}) {
    final kind = FileSystemEntity.typeSync(path, followLinks: false);
    if ((kind != FileSystemEntityType.notFound &&
            kind != FileSystemEntityType.file) ||
        (absent && kind != FileSystemEntityType.notFound)) {
      throw const FormatException('Unexpected narration storage target.');
    }
    return File(path);
  }

  File _audio(CatalogBook book, String key) {
    if (!_keyPattern.hasMatch(key)) {
      throw const FormatException('Invalid audio key.');
    }
    return _ownedFile('${_directory(book).path}/$key.wav');
  }

  File _timingFile(File audio) =>
      File('${audio.path.substring(0, audio.path.length - 4)}.timing.json');

  List<File> _companions(File audio) => [
    _timingFile(audio),
    File('${_timingFile(audio).path}.tmp'),
    File('${audio.path}.tmp'),
  ];

  @override
  Future<NarrationManifest> load(CatalogBook book) => _serial(() async {
    for (final file in AtomicJsonFile(
      File('${_directory(book).path}/manifest.json'),
    ).generations) {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      try {
        final json = (jsonDecode(await file.readAsString()) as Map)
            .cast<String, dynamic>();
        if (json['bookHash'] != book.hash) continue;
        return NarrationManifest.fromJson(json);
      } on Object {
        continue;
      }
    }
    return const NarrationManifest();
  });

  @override
  Future<void> save(CatalogBook book, NarrationManifest manifest) =>
      _serial(() async {
        final directory = _directory(book);
        await directory.create();
        final file = _ownedFile('${directory.path}/manifest.json');
        final temporary = _ownedFile('${file.path}.tmp');
        final backup = _ownedFile('${file.path}.bak');
        // Use the shared generation protocol, but never recursively create its
        // parent: a concurrently deleted publication must remain deleted.
        await temporary.writeAsString(
          jsonEncode({'bookHash': book.hash, ...manifest.toJson()}),
          flush: true,
        );
        _directory(book);
        _ownedFile(file.path);
        _ownedFile(temporary.path);
        _ownedFile(backup.path);
        if (backup.existsSync()) backup.deleteSync();
        if (file.existsSync()) file.renameSync(backup.path);
        temporary.renameSync(file.path);
        if (backup.existsSync()) backup.deleteSync();
      });

  @override
  Future<NarrationAudioAsset?> cached(CatalogBook book, String key) =>
      _serial(() async {
        final file = _audio(book, key);
        if (!await file.exists()) return null;
        final Duration duration;
        try {
          duration = await validateNarrationWav(file);
        } on FormatException {
          return null;
        } on FileSystemException {
          return null;
        }
        final timing = await _readTiming(file, key, duration);
        _directory(book);
        _ownedFile(file.path);
        await file.setLastModified(DateTime.now());
        return NarrationAudioAsset(path: file.path, timing: timing);
      });

  Future<NarrationTiming?> _readTiming(
    File audio,
    String key,
    Duration duration,
  ) async {
    final file = _timingFile(audio);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    try {
      if (await file.length() > _maxTimingBytes) return null;
      final timing = NarrationTiming.tryFromJson(
        jsonDecode(await file.readAsString()),
      );
      return _validTiming(timing, key, duration);
    } on Object {
      // A companion is presentation metadata, never an audio availability gate.
      return null;
    }
  }

  NarrationTiming? _validTiming(
    NarrationTiming? timing,
    String key,
    Duration duration,
  ) {
    if (timing == null ||
        !_keyPattern.hasMatch(timing.chunkId) ||
        !_keyPattern.hasMatch(timing.sourceDigest) ||
        !timing.matches(audioKey: key, duration: duration)) {
      return null;
    }
    return timing;
  }

  @override
  Future<String> put(
    CatalogBook book,
    String key,
    Uint8List bytes, {
    bool Function()? isCurrent,
  }) async {
    if (bytes.length < 44 || bytes.length > maxNarrationAudioBytes) {
      throw const FormatException('Invalid narration WAV size.');
    }
    final asset = await create(book, key, (path) async {
      await File(path).writeAsBytes(bytes, flush: true);
      return null;
    }, isCurrent: isCurrent ?? () => true);
    return asset.path;
  }

  /// Reserves staging ownership while running synthesis outside the root queue.
  @override
  Future<NarrationAudioAsset> create(
    CatalogBook book,
    String key,
    Future<NarrationTiming?> Function(String stagingPath) writer, {
    required bool Function() isCurrent,
  }) async {
    final (write, predecessor) = await _serial(() async {
      if (!isCurrent()) throw StateError('Narration generation changed.');
      final audio = _audio(book, key);
      final claims = _writers.putIfAbsent(audio.path, () => []);
      final predecessor = claims.isEmpty ? null : claims.last.settled.future;
      final write = _NarrationWrite(audio, _timingFile(audio));
      claims.add(write);
      return (write, predecessor);
    });
    final audio = write.audio;
    final temporary = write.temporary;
    final timingFile = write.timingFile;
    final timingTemporary = write.timingTemporary;
    void checkCurrent() {
      if (write.invalidated || !isCurrent()) {
        throw StateError('Narration generation changed.');
      }
    }

    try {
      // A live predecessor owns these exact staging names until its cleanup,
      // including after cancellation. Other keys and manifests stay available.
      if (predecessor != null) await predecessor;
      await _serial(() async {
        checkCurrent();
        _directory(book);
        await audio.parent.create();
        checkCurrent();
        _directory(book);
        _ownedFile(temporary.path);
        _ownedFile(timingFile.path);
        _ownedFile(timingTemporary.path);
        // Only this key's settled predecessors may have left crash recovery
        // files. Live writers for other keys are never removed here.
        if (temporary.existsSync()) temporary.deleteSync();
        if (timingTemporary.existsSync()) timingTemporary.deleteSync();
        write.prepared = true;
      });
      final generatedTiming = await writer(temporary.path);
      return await _serial(() async {
        checkCurrent();
        _directory(book);
        _ownedFile(temporary.path);
        final duration = await validateNarrationWav(temporary);
        var timing = _validTiming(generatedTiming, key, duration);
        _ownedFile(timingTemporary.path, absent: true);
        if (timing != null) {
          try {
            final bytes = utf8.encode(jsonEncode(timing.toJson()));
            if (bytes.length > _maxTimingBytes) {
              timing = null;
            } else {
              await timingTemporary.writeAsBytes(bytes, flush: true);
            }
          } on FileSystemException {
            timing = null;
          }
        }
        // Flush a callback-written file even when its writer did not request it.
        _directory(book);
        _ownedFile(temporary.path);
        final handle = await temporary.open(mode: FileMode.append);
        try {
          await handle.flush();
        } finally {
          await handle.close();
        }
        checkCurrent();
        _directory(book);
        _ownedFile(audio.path);
        _ownedFile(temporary.path);
        _ownedFile(timingFile.path);
        _ownedFile(timingTemporary.path);
        // No asynchronous gap between the ownership fence and publication.
        // Never pair replacement audio with its predecessor's cue timeline.
        if (timingFile.existsSync()) timingFile.deleteSync();
        temporary.renameSync(audio.path);
        if (timing != null) {
          try {
            timingTemporary.renameSync(timingFile.path);
          } on FileSystemException {
            timing = null;
          }
        }
        await _evict();
        return NarrationAudioAsset(path: audio.path, timing: timing);
      });
    } finally {
      await _serial(() async {
        try {
          if (write.prepared) {
            // A deleted or linked parent cannot authorize cleanup elsewhere.
            _directory(book);
            _removeTemporary(temporary);
            _removeTemporary(timingTemporary);
          }
        } on FormatException {
          // Book deletion may already have removed this owned directory.
        } finally {
          final claims = _writers[audio.path]!;
          claims.remove(write);
          if (claims.isEmpty) _writers.remove(audio.path);
          write.settled.complete();
        }
      });
    }
  }

  void _removeTemporary(File file) {
    try {
      if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        file.deleteSync();
      }
    } on FileSystemException {
      // A deletion barrier may already have removed the containing directory.
    }
  }

  @override
  void pin(Set<String> keys) {
    _pins = Set.of(keys);
  }

  Future<List<File>> _audioFiles(
    Directory directory, {
    bool cleanOrphans = false,
  }) async {
    final files = <File>[];
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return files;
    }
    await for (final file in directory.list(followLinks: false)) {
      if (file is! File ||
          await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
        continue;
      }
      if (_audioPattern.hasMatch(file.path)) {
        files.add(file);
      } else if (cleanOrphans) {
        final match = _companionPattern.firstMatch(file.path);
        if (match != null &&
            !_writers.containsKey('${directory.path}/${match.group(1)}.wav') &&
            await FileSystemEntity.type(
                  '${directory.path}/${match.group(1)}.wav',
                  followLinks: false,
                ) ==
                FileSystemEntityType.notFound) {
          // Only unclaimed crash leftovers can be recovered while native
          // writers run outside the root queue.
          await file.delete();
        }
      }
    }
    return files;
  }

  Future<int> _entryBytes(File audio) async {
    var bytes = await audio.length();
    for (final file in _companions(audio)) {
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        bytes += await file.length();
      }
    }
    return bytes;
  }

  Future<void> _deleteEntry(File audio) async {
    // Remove metadata first, so a crash leaves a counted playable WAV, not an
    // uncounted orphan companion.
    for (final file in [..._companions(audio), audio]) {
      if (_writers.containsKey(audio.path) &&
          (file.path == '${audio.path}.tmp' ||
              file.path == '${_timingFile(audio).path}.tmp')) {
        continue;
      }
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await file.delete();
      }
    }
  }

  Future<void> _evict() async {
    final files = <File>[];
    final books = Directory('${root.absolute.path}/books');
    if (await FileSystemEntity.type(root.absolute.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await FileSystemEntity.type(books.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      return;
    }
    await for (final book in books.list(followLinks: false)) {
      if (book is! Directory ||
          !_keyPattern.hasMatch(
            book.uri.pathSegments.where((part) => part.isNotEmpty).last,
          )) {
        continue;
      }
      files.addAll(
        await _audioFiles(
          Directory('${book.path}/narration'),
          cleanOrphans: true,
        ),
      );
    }
    final stats = {for (final file in files) file: await file.stat()};
    final sizes = {for (final file in files) file: await _entryBytes(file)};
    files.sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));
    var total = sizes.values.fold(0, (sum, size) => sum + size);
    for (final file in files) {
      if (total <= maxBytes) break;
      final key = file.uri.pathSegments.last.split('.').first;
      if (_pins.contains(key)) continue;
      await _deleteEntry(file);
      total -= sizes[file]!;
    }
  }

  @override
  Future<int> cachedBytes(CatalogBook book) => _serial(() async {
    var bytes = 0;
    for (final file in await _audioFiles(_directory(book))) {
      bytes += await _entryBytes(file);
    }
    return bytes;
  });

  @override
  Future<void> clear(CatalogBook book) => _serial(() async {
    final directory = _directory(book);
    for (final entry in _writers.entries) {
      if (entry.key.startsWith('${directory.path}/')) {
        for (final write in entry.value) {
          write.invalidated = true;
        }
      }
    }
    if (!await directory.exists()) return;
    final owned = RegExp(
      r'/[a-f0-9]{64}\.(?:wav(?:\.tmp)?|timing\.json(?:\.tmp)?)$',
    );
    await for (final file in directory.list(followLinks: false)) {
      if (file is File &&
          owned.hasMatch(file.path) &&
          await FileSystemEntity.type(file.path, followLinks: false) ==
              FileSystemEntityType.file) {
        await file.delete();
      }
    }
  });
}

/// One key's staging ownership, retained until its writer and cleanup settle.
class _NarrationWrite {
  _NarrationWrite(this.audio, this.timingFile)
    : temporary = File('${audio.path}.tmp'),
      timingTemporary = File('${timingFile.path}.tmp');

  final File audio;
  final File temporary;
  final File timingFile;
  final File timingTemporary;
  final settled = Completer<void>();
  bool prepared = false;
  bool invalidated = false;
}
