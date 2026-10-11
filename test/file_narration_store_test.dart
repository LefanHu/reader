import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/catalog/file_catalog_store.dart';
import 'package:reader/narration/file_narration_store.dart';
import 'package:reader/narration/narration_cue.dart';
import 'package:reader/narration/narration_manifest.dart';
import 'package:reader/narration/narration_timing.dart';
import 'package:reader/narration/narration_wav.dart';
import 'package:reader/narration/source.dart';
import 'package:reader/text/narration_range.dart';
import 'package:reader/text/text_position.dart';

import 'fixtures/narration_audio.dart';
import 'support/memory_narration_store.dart';
import 'fixtures/catalog_book.dart';

NarrationTiming _timing(
  String key, {
  Duration duration = const Duration(seconds: 1),
}) => NarrationTiming(
  audioKey: key,
  chunkId: 'd' * 64,
  sourceDigest: 'e' * 64,
  synthesisFingerprint: 'apple-test-os',
  duration: duration,
  cues: [
    NarrationCue(
      time: const Duration(milliseconds: 100),
      range: NarrationRange(
        const TextPosition(sectionId: 's0', blockId: 'p0'),
        const TextPosition(sectionId: 's0', blockId: 'p0', offset: 5),
      ),
      kind: NarrationCueKind.word,
    ),
    NarrationCue(
      time: const Duration(milliseconds: 600),
      range: NarrationRange(
        const TextPosition(sectionId: 's0', blockId: 'p0', offset: 7),
        const TextPosition(sectionId: 's0', blockId: 'p0', offset: 12),
      ),
      kind: NarrationCueKind.word,
    ),
  ],
);

void main() {
  late Directory root;
  late CatalogBook book;
  late FileNarrationStore store;
  final key = 'a' * 64;

  Directory directory() =>
      Directory('${File(book.path).parent.path}/narration');
  File audio(String value) => File('${directory().path}/$value.wav');
  File companion(String value) =>
      File('${directory().path}/$value.timing.json');

  Future<void> generate(String value, {NarrationTiming? timing}) async {
    await store.create(book, value, (path) async {
      expect(path, '${audio(value).path}.tmp');
      expect(
        await FileSystemEntity.type(path, followLinks: false),
        FileSystemEntityType.notFound,
      );
      await File(path).writeAsBytes(testWav(), flush: true);
      return timing;
    }, isCurrent: () => true);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('reader_atomic_narration_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    book = await importTextBook(root, 'Hello, world. Another sentence.');
    store = FileNarrationStore(root);
  });

  test(
    'publishes PCM WAV and versioned timing as one owned cache entry',
    () async {
      final timing = _timing(key);
      await generate(key, timing: timing);
      final asset = (await store.cached(book, key))!;
      expect(asset.path, audio(key).path);
      expect(asset.timing!.toJson(), timing.toJson());
      expect(jsonDecode(await companion(key).readAsString()), timing.toJson());
      expect(await File('${audio(key).path}.tmp').exists(), isFalse);
      expect(await File('${companion(key).path}.tmp').exists(), isFalse);
      expect(
        await store.cachedBytes(book),
        testWav().length + await companion(key).length(),
      );

      // A new owner reads persisted timing; it is not a process-memory cursor.
      final reopened = await FileNarrationStore(root).cached(book, key);
      expect(reopened!.timing!.toJson(), timing.toJson());
    },
  );

  test(
    'missing, corrupt and incompatible companions preserve playable audio',
    () async {
      await generate(key, timing: _timing(key));
      final valid = _timing(key).toJson();
      final invalid = <Object>[
        '{not-json',
        {...valid, 'version': 99},
        {...valid, 'audioKey': 'b' * 64},
        {...valid, 'chunkId': ''},
        {...valid, 'sourceDigest': 'not-a-source-digest'},
        {...valid, 'durationUs': 2000000},
        {
          ...valid,
          'cues': [
            {...(valid['cues'] as List).first as Map, 'timeUs': 1000001},
          ],
        },
        {
          ...valid,
          'cues': [
            {'kind': 'word', 'timeUs': 0, 'start': {}, 'end': {}},
          ],
        },
      ];
      for (final json in invalid) {
        await companion(key)
            .writeAsString(json is String ? json : jsonEncode(json));
        final asset = await store.cached(book, key);
        expect(asset, isNotNull);
        expect(asset!.timing, isNull);
        expect(
          await validateNarrationWav(File(asset.path)),
          const Duration(seconds: 1),
        );
      }
      await companion(key).delete();
      expect((await store.cached(book, key))!.timing, isNull);
    },
  );

  test(
    'invalid generated timing falls back rather than rejecting valid WAV',
    () async {
      await generate(key, timing: _timing('b' * 64));
      expect((await store.cached(book, key))!.timing, isNull);
      expect(await companion(key).exists(), isFalse);
      await generate(
        key,
        timing: _timing(key, duration: const Duration(seconds: 2)),
      );
      expect((await store.cached(book, key))!.timing, isNull);
      expect(await companion(key).exists(), isFalse);
    },
  );

  test(
    'replacing audio removes previous timing before publishing new WAV',
    () async {
      await generate(key, timing: _timing(key));
      await store.put(book, key, testWav(samples: 12000));
      final asset = (await store.cached(book, key))!;
      expect(asset.timing, isNull);
      expect(await companion(key).exists(), isFalse);
      expect(
        await validateNarrationWav(File(asset.path)),
        const Duration(milliseconds: 500),
      );
      expect(await store.cachedBytes(book), testWav(samples: 12000).length);
    },
  );

  test('pending third writer leaves ready audio and manifest persistence available', () async {
    final secondKey = 'b' * 64, thirdKey = 'c' * 64;
    await generate(key, timing: _timing(key));
    await generate(secondKey, timing: _timing(secondKey));
    final started = Completer<void>(), release = Completer<void>();
    final third = store.create(book, thirdKey, (path) async {
      await File(path).writeAsBytes(testWav(), flush: true);
      started.complete();
      await release.future;
      return _timing(thirdKey);
    }, isCurrent: () => true);
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await third.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    });
    await started.future;

    // Another store shares the root queue, but never waits for clip three
    // before loading completed clip two or flushing the playback manifest.
    final reopened = FileNarrationStore(root);
    final ready = await reopened
        .cached(book, secondKey)
        .timeout(const Duration(seconds: 2));
    expect(ready!.path, audio(secondKey).path);
    expect(ready.timing!.toJson(), _timing(secondKey).toJson());
    const manifest = NarrationManifest(
      account: 'account',
      cloudBookId: 'cloud-book',
    );
    await reopened.save(book, manifest).timeout(const Duration(seconds: 2));
    expect(
      (await reopened.load(book).timeout(const Duration(seconds: 2))).toJson(),
      manifest.toJson(),
    );
    expect(release.isCompleted, isFalse);
    expect(
      await reopened.cached(book, thirdKey).timeout(const Duration(seconds: 2)),
      isNull,
    );

    // Publication's orphan recovery must leave a live, still-private writer.
    await generate('f' * 64).timeout(const Duration(seconds: 2));
    expect(await File('${audio(thirdKey).path}.tmp').exists(), isTrue);
    expect(await companion(thirdKey).exists(), isFalse);
    release.complete();
    await third;
    expect((await reopened.cached(book, thirdKey))!.timing, isNotNull);
  });

  test(
    'cancellation removes owned staging and leaves previous audio intact',
    () async {
      await generate(key, timing: _timing(key));
      final started = Completer<void>(), release = Completer<void>();
      var current = true;
      final operation = store.create(book, key, (path) async {
        await File(path).writeAsBytes(testWav(samples: 12000), flush: true);
        started.complete();
        await release.future;
        return null;
      }, isCurrent: () => current);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final rejected = expectLater(
        operation,
        throwsA(isA<NarrationCancelled>()),
      );
      await started.future;
      current = false;
      release.complete();
      await rejected;
      expect(await File('${audio(key).path}.tmp').exists(), isFalse);
      final asset = (await store.cached(book, key))!;
      expect(asset.timing!.toJson(), _timing(key).toJson());
      expect(
        await validateNarrationWav(File(asset.path)),
        const Duration(seconds: 1),
      );
    },
  );

  test('queued cloud publication honors its generation fence', () async {
    final started = Completer<void>(), release = Completer<void>();
    final first = store.create(book, key, (path) async {
      started.complete();
      await release.future;
      await File(path).writeAsBytes(testWav(), flush: true);
      return null;
    }, isCurrent: () => true);
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    await started.future;
    var current = true;
    final queued = store.put(
      book,
      'b' * 64,
      testWav(),
      isCurrent: () => current,
    );
    final rejected = expectLater(queued, throwsA(isA<NarrationCancelled>()));
    current = false;
    release.complete();
    await first;
    await rejected;
    expect(await store.cached(book, 'b' * 64), isNull);
  });

  test(
    'book deletion during generation never resurrects its directory',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      final operation = store.create(book, key, (path) async {
        await File(path).writeAsBytes(testWav(), flush: true);
        started.complete();
        await release.future;
        return _timing(key);
      }, isCurrent: () => true);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final rejected = expectLater(operation, throwsFormatException);
      await started.future;
      await FileCatalogStore(root).deleteFiles(book);
      release.complete();
      await rejected;
      expect(await File(book.path).parent.exists(), isFalse);
    },
  );

  test(
    'writer errors and malformed PCM remove their owned temporary output',
    () async {
      final malformed = <Uint8List>[
        testWav(samples: 0),
        testWav()..[20] = 3,
        testWav()..[32] = 4,
        testWav()..[40] = 1,
        testWav()..[4] = 0,
      ];
      for (final bytes in malformed) {
        await expectLater(
          store.create(book, key, (path) async {
            await File(path).writeAsBytes(bytes, flush: true);
            return _timing(key);
          }, isCurrent: () => true),
          throwsFormatException,
        );
        expect(await audio(key).exists(), isFalse);
        expect(await File('${audio(key).path}.tmp').exists(), isFalse);
        expect(await companion(key).exists(), isFalse);
      }
      await expectLater(
        store.create(book, key, (path) async {
          await File(path).writeAsBytes(testWav());
          throw StateError('writer failed');
        }, isCurrent: () => true),
        throwsStateError,
      );
      expect(await File('${audio(key).path}.tmp').exists(), isFalse);
    },
  );

  test(
    'PCM format extensions are accepted without assuming cloud header size',
    () async {
      final source = testWav();
      final extended = Uint8List(source.length + 2)
        ..setRange(0, 36, source)
        ..setRange(38, source.length + 2, source, 36);
      final data = ByteData.sublistView(extended);
      data.setUint32(4, extended.length - 8, Endian.little);
      data.setUint32(16, 18, Endian.little);
      await store.put(book, key, extended);
      expect(
        await validateNarrationWav(audio(key)),
        const Duration(seconds: 1),
      );
    },
  );

  test(
    'extensible PCM16 WAV remains playable but float subtype is rejected',
    () async {
      final source = testWav();
      final extended = Uint8List(source.length + 24)
        ..setRange(0, 36, source)
        ..setRange(60, source.length + 24, source, 36);
      final data = ByteData.sublistView(extended);
      data.setUint32(4, extended.length - 8, Endian.little);
      data.setUint32(16, 40, Endian.little);
      data.setUint16(20, 0xfffe, Endian.little);
      data.setUint16(36, 22, Endian.little);
      data.setUint16(38, 16, Endian.little);
      data.setUint32(44, 1, Endian.little);
      data.setUint32(48, 0x00100000, Endian.little);
      data.setUint32(52, 0xaa000080, Endian.little);
      data.setUint32(56, 0x719b3800, Endian.little);
      await store.put(book, key, extended);
      expect(
        await validateNarrationWav(audio(key)),
        const Duration(seconds: 1),
      );
      data.setUint32(44, 3, Endian.little);
      await expectLater(
        store.put(book, 'b' * 64, extended),
        throwsFormatException,
      );
      expect(await audio('b' * 64).exists(), isFalse);
    },
  );

  test(
    'oversized generated WAV is rejected without loading its payload',
    () async {
      await expectLater(
        store.create(book, key, (path) async {
          final file = await File(path).open(mode: FileMode.write);
          try {
            await file.truncate(maxNarrationAudioBytes + 1);
          } finally {
            await file.close();
          }
          return null;
        }, isCurrent: () => true),
        throwsFormatException,
      );
      expect(await File('${audio(key).path}.tmp').exists(), isFalse);
    },
  );

  test(
    'recovers regular crashed staging but refuses links and traversal',
    () async {
      await directory().create();
      await File('${audio(key).path}.tmp').writeAsString('interrupted WAV');
      await File('${companion(key).path}.tmp')
          .writeAsString('interrupted timing');
      await generate(key, timing: _timing(key));
      final outside = File('${root.path}/untouched.wav');
      await outside.writeAsString('outside');
      await Link('${audio('b' * 64).path}.tmp').create(outside.path);
      await expectLater(
        store.create(book, 'b' * 64, (path) async {
          fail('A link must be refused before the writer runs.');
        }, isCurrent: () => true),
        throwsFormatException,
      );
      await expectLater(
        store.put(book, '../escape', testWav()),
        throwsFormatException,
      );
      expect(await outside.readAsString(), 'outside');
      expect(
        await FileSystemEntity.type(
          '${audio('b' * 64).path}.tmp',
          followLinks: false,
        ),
        FileSystemEntityType.link,
      );
    },
  );

  test(
    'timing links fall back on read and block unsafe replacement writes',
    () async {
      await generate(key);
      final outside = File('${root.path}/untouched.json');
      await outside.writeAsString(jsonEncode(_timing(key).toJson()));
      await Link(companion(key).path).create(outside.path);
      expect((await store.cached(book, key))!.timing, isNull);
      await expectLater(store.put(book, key, testWav()), throwsFormatException);
      await store.clear(book);
      expect(await outside.exists(), isTrue);
      expect(
        await FileSystemEntity.type(companion(key).path, followLinks: false),
        FileSystemEntityType.link,
      );
    },
  );

  test('root and narration directory links cannot authorize writers', () async {
    final alias = Link('${root.path}/catalog-link');
    await alias.create(root.path);
    await expectLater(
      FileNarrationStore(Directory(alias.path)).put(book, key, testWav()),
      throwsFormatException,
    );
    final outside = await Directory('${root.path}/unrelated').create();
    await Link(directory().path).create(outside.path);
    await expectLater(store.put(book, key, testWav()), throwsFormatException);
    expect(await outside.list().isEmpty, isTrue);
  });

  test(
    'paired LRU includes companion bytes and preserves all pinned entries',
    () async {
      final keys = ['a' * 64, 'b' * 64, 'c' * 64, 'f' * 64];
      final timingBytes = utf8.encode(jsonEncode(_timing(key).toJson())).length;
      store = FileNarrationStore(
        root,
        maxBytes: (testWav().length + timingBytes) * 3,
      );
      store.pin(keys.take(3).toSet());
      for (final value in keys.take(3)) {
        await generate(value, timing: _timing(value));
      }
      store.pin({keys[0], keys[2], keys[3]});
      await File('${audio(keys[1]).path}.tmp').writeAsString('orphan');
      await File('${companion(keys[1]).path}.tmp').writeAsString('orphan');
      await generate(keys[3], timing: _timing(keys[3]));
      expect(await store.cached(book, keys[1]), isNull);
      for (final file in [
        audio(keys[1]),
        companion(keys[1]),
        File('${audio(keys[1]).path}.tmp'),
        File('${companion(keys[1]).path}.tmp'),
      ]) {
        expect(await file.exists(), isFalse);
      }
      for (final value in [keys[0], keys[2], keys[3]]) {
        expect((await store.cached(book, value))!.timing, isNotNull);
      }
      expect(
        await store.cachedBytes(book),
        (testWav().length + timingBytes) * 3,
      );
    },
  );

  test('eviction removes old audio without deleting its active replacement staging', () async {
    final timingBytes = utf8.encode(jsonEncode(_timing(key).toJson())).length;
    store = FileNarrationStore(
      root,
      maxBytes: (testWav().length + timingBytes) * 2,
    );
    await generate(key, timing: _timing(key));
    await generate('b' * 64);
    await audio(key).setLastModified(DateTime(2000));
    final started = Completer<void>(), release = Completer<void>();
    final replacement = store.create(book, key, (path) async {
      await File(path).writeAsBytes(testWav(samples: 12000), flush: true);
      started.complete();
      await release.future;
      return null;
    }, isCurrent: () => true);
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await replacement.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
    });
    await started.future;
    await generate('c' * 64).timeout(const Duration(seconds: 2));
    expect(await store.cached(book, key), isNull);
    expect(await companion(key).exists(), isFalse);
    expect(await File('${audio(key).path}.tmp').exists(), isTrue);
    release.complete();
    final asset = await replacement;
    expect(asset.timing, isNull);
    expect(
      await validateNarrationWav(File(asset.path)),
      const Duration(milliseconds: 500),
    );
    expect(await File('${audio(key).path}.tmp').exists(), isFalse);
  });

  test('publication removes orphan cache files without touching links or unrelated data', () async {
    await directory().create();
    final orphanKey = 'b' * 64;
    final orphanAudio = File('${audio(orphanKey).path}.tmp');
    final orphanTiming = companion(orphanKey);
    final orphanTimingTemporary = File('${orphanTiming.path}.tmp');
    for (final file in [orphanAudio, orphanTiming, orphanTimingTemporary]) {
      await file.writeAsString('interrupted generation');
    }
    final outside = File('${root.path}/outside.json');
    await outside.writeAsString('keep');
    final linked = Link(companion('c' * 64).path);
    await linked.create(outside.path);
    final unrelated = File('${directory().path}/unrelated.tmp');
    await unrelated.writeAsString('keep');
    await generate(key, timing: _timing(key));
    for (final file in [orphanAudio, orphanTiming, orphanTimingTemporary]) {
      expect(await file.exists(), isFalse);
    }
    expect(await linked.exists(), isTrue);
    expect(await outside.readAsString(), 'keep');
    expect(await unrelated.readAsString(), 'keep');
  });

  test(
    'store instances serialize staging ownership for the same catalog root',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      final first = store.create(book, key, (path) async {
        await File(path).writeAsBytes(testWav(), flush: true);
        started.complete();
        await release.future;
        return _timing(key);
      }, isCurrent: () => true);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await started.future;
      var replacementStarted = false;
      final second = FileNarrationStore(root).create(book, key, (path) async {
        replacementStarted = true;
        expect(await File(path).exists(), isFalse);
        await File(path).writeAsBytes(testWav(samples: 12000), flush: true);
        return null;
      }, isCurrent: () => true);
      await pumpEventQueue();
      expect(replacementStarted, isFalse);
      expect(await File('${audio(key).path}.tmp').length(), testWav().length);
      release.complete();
      await first;
      await second;
      expect((await store.cached(book, key))!.timing, isNull);
      expect(
        await validateNarrationWav(audio(key)),
        const Duration(milliseconds: 500),
      );
    },
  );

  test(
    'clear fences active and waiting writers before their late results settle',
    () async {
      const manifest = NarrationManifest(cloudBookId: 'cloud-book');
      await store.save(book, manifest);
      await generate(key, timing: _timing(key));
      final started = Completer<void>(), release = Completer<void>();
      final operation = store.create(book, key, (path) async {
        await File(path).writeAsBytes(testWav(), flush: true);
        started.complete();
        await release.future;
        // A late callback can recreate its cleared staging file, but may never
        // republish it even when the caller's generation predicate stays true.
        await File(path).writeAsBytes(testWav(), flush: true);
        return _timing(key);
      }, isCurrent: () => true);
      final rejected = expectLater(
        operation,
        throwsA(isA<NarrationCancelled>()),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await operation.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        );
      });
      await started.future;
      final queued = FileNarrationStore(root).create(book, key, (path) async {
        fail('A pre-clear queued writer must not acquire staging afterwards.');
      }, isCurrent: () => true);
      final queuedRejected = expectLater(
        queued,
        throwsA(isA<NarrationCancelled>()),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await queued.then<void>((_) {}, onError: (Object _, StackTrace _) {});
      });
      await FileNarrationStore(root)
          .clear(book)
          .timeout(const Duration(seconds: 2));
      expect(release.isCompleted, isFalse);
      expect(await store.cached(book, key), isNull);
      expect((await store.load(book)).toJson(), manifest.toJson());
      release.complete();
      await rejected;
      await queuedRejected;
      expect(await store.cached(book, key), isNull);
      expect(await File('${audio(key).path}.tmp').exists(), isFalse);
      expect(await companion(key).exists(), isFalse);
      expect(await File('${companion(key).path}.tmp').exists(), isFalse);

      // Settled stale claims neither poison nor clean up a new generation.
      await generate(key, timing: _timing(key));
      expect((await store.cached(book, key))!.timing, isNotNull);
    },
  );

  test('clear removes matching companions and staging, never resume or unrelated files', () async {
    const manifest = NarrationManifest(
      account: 'account',
      cloudBookId: 'cloud-book',
    );
    await store.save(book, manifest);
    await generate(key, timing: _timing(key));
    await File('${audio('b' * 64).path}.tmp').writeAsString('interrupted');
    await File('${companion('b' * 64).path}.tmp').writeAsString('interrupted');
    await companion('c' * 64).writeAsString('orphan');
    final unrelated = File('${directory().path}/user.wav');
    await unrelated.writeAsString('keep');
    await store.clear(book);
    expect(await store.cachedBytes(book), 0);
    expect(await store.cached(book, key), isNull);
    expect(await companion(key).exists(), isFalse);
    expect(await File('${audio('b' * 64).path}.tmp').exists(), isFalse);
    expect(await File('${companion('b' * 64).path}.tmp').exists(), isFalse);
    expect(await companion('c' * 64).exists(), isFalse);
    expect(await unrelated.readAsString(), 'keep');
    expect((await store.load(book)).toJson(), manifest.toJson());
  });

  test('memory writer owns real staging, paired cleanup and deterministic teardown', () async {
    final memory = MemoryNarrationStore();
    final asset = await memory.create(book, key, (path) async {
      expect(await File(path).exists(), isFalse);
      await File(path).writeAsBytes(testWav(), flush: true);
      return _timing(key);
    }, isCurrent: () => true);
    final timingFile = File('${File(asset.path).parent.path}/$key.timing.json');
    expect(await File(asset.path).exists(), isTrue);
    expect(await timingFile.exists(), isTrue);
    expect(
      (await memory.cached(book, key))!.timing!.toJson(),
      _timing(key).toJson(),
    );
    expect(
      await memory.cachedBytes(book),
      testWav().length + await timingFile.length(),
    );
    final fixture = File(asset.path).parent.parent.parent.parent;
    await memory.clear(book);
    expect(await File(asset.path).exists(), isFalse);
    expect(await timingFile.exists(), isFalse);
    await memory.dispose();
    expect(await fixture.exists(), isFalse);
  });

  test(
    'memory clear fences an unfinished writer and removes its output',
    () async {
      final memory = MemoryNarrationStore();
      final started = Completer<String>(), release = Completer<void>();
      final operation = memory.create(book, key, (path) async {
        await File(path).writeAsBytes(testWav(), flush: true);
        started.complete(path);
        await release.future;
        return _timing(key);
      }, isCurrent: () => true);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final rejected = expectLater(
        operation,
        throwsA(isA<NarrationCancelled>()),
      );
      final path = await started.future;
      await memory.clear(book);
      release.complete();
      await rejected;
      expect(await File(path).exists(), isFalse);
      expect(await memory.cached(book, key), isNull);
      expect(memory.files, isEmpty);
    },
  );

  group('Private audio storage', () {
    setUp(() {
      store = FileNarrationStore(root, maxBytes: testWav().length * 2);
    });
    test(
      'LRU evicts oldest unpinned audio and clearing preserves registration',
      () async {
        const manifest = NarrationManifest(
          account: 'account',
          cloudBookId: 'cloud-book',
        );
        await store.save(book, manifest);
        store.pin({'a' * 64});
        await store.put(book, 'a' * 64, testWav());
        await store.put(book, 'b' * 64, testWav());
        await store.put(book, 'c' * 64, testWav());
        expect(await store.cached(book, 'a' * 64), isNotNull);
        expect(await store.cached(book, 'b' * 64), isNull);
        expect(await store.cachedBytes(book), testWav().length * 2);
        await store.clear(book);
        expect(await store.cachedBytes(book), 0);
        expect(await store.cached(book, 'a' * 64), isNull);
        expect((await store.load(book)).cloudBookId, 'cloud-book');
      },
    );
    test(
      'store refuses symlink audio and writes after owned book deletion',
      () async {
        final directory = Directory('${File(book.path).parent.path}/narration');
        await directory.create();
        await Link('${directory.path}/${'a' * 64}.wav')
            .create('${root.path}/outside.wav');
        expect(await store.cachedBytes(book), 0);
        await expectLater(
          store.put(book, 'a' * 64, testWav()),
          throwsFormatException,
        );
        await FileCatalogStore(root).deleteFiles(book);
        await expectLater(
          store.save(book, const NarrationManifest()),
          throwsFormatException,
        );
      },
    );
    test('resume sidecars recover temporary generation and preserve complete anchors', () async {
      const anchor = TextPosition(sectionId: 's0', blockId: 'p0', offset: 5);
      const value = NarrationManifest(
        account: 'account',
        cloudBookId: 'cloud-book',
        anchor: anchor,
        chunkId: 'chunk',
        chunkStart: TextPosition(sectionId: 's0', blockId: 'p1'),
        offsetMs: 1234,
      );
      await store.save(book, value);
      final file = File(
        '${File(book.path).parent.path}/narration/manifest.json',
      );
      await file.rename('${file.path}.tmp');
      await file.writeAsString('{bad');
      expect((await store.load(book)).anchor, anchor);
      expect(
        (await store.load(book)).chunkStart,
        const TextPosition(sectionId: 's0', blockId: 'p1'),
      );
      expect((await store.load(book)).offsetMs, 1234);
    });
  });
}
