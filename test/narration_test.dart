import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/book_service.dart';
import 'package:reader/models.dart';
import 'package:reader/narration/models.dart';
import 'package:reader/narration/session.dart';
import 'package:reader/narration/store.dart';
import 'package:reader/storage.dart';
import 'package:reader/text/document.dart';
import 'package:reader/text/narration.dart';

import 'fakes.dart';
import 'support/narration_fakes.dart';

Future<void> settle() => pumpEventQueue(times: 30);

void main() {
  test('chunks preserve exact Unicode prose, deterministic identities and complete anchors', () {
    final text = 'First sentence. 中文 العربية e\u0301 👩🏽‍🚀 🇨🇦 ' * 180;
    final section = TextSection(
      id: 's0',
      blocks: [
        TextBlock(id: 'p0', text: text),
        const TextBlock(id: 'p1', text: 'Second paragraph.'),
      ],
    );
    final chunks = narrationChunks(section);
    expect(
      chunks
          .where((chunk) => chunk.start.blockId == 'p0')
          .map((chunk) => chunk.text)
          .join(),
      text,
    );
    expect(chunks.last.text, 'Second paragraph.');
    expect(
      chunks.map((chunk) => chunk.id),
      narrationChunks(section).map((chunk) => chunk.id),
    );
    for (final chunk in chunks) {
      expect(chunk.text.length, lessThanOrEqualTo(3000));
      final block = section.blocks.firstWhere(
        (block) => block.id == chunk.start.blockId,
      );
      expect(
        chunk.text,
        block.text.substring(chunk.start.offset, chunk.end.offset),
      );
      expect(graphemeFloor(block.text, chunk.start.offset), chunk.start.offset);
      expect(graphemeFloor(block.text, chunk.end.offset), chunk.end.offset);
      expect(TextPosition.fromJson(chunk.end.toJson()), chunk.end);
    }
    final from = TextPosition(
      sectionId: 's0',
      blockId: 'p0',
      offset: text.characters.first.length,
    );
    expect(narrationChunks(section, from: from).first.start, from);
    expect(
      narrationChunks(section, from: from)
          .where((chunk) => chunk.start.blockId == 'p0')
          .map((chunk) => chunk.text)
          .join(),
      text.substring(from.offset),
    );
  });

  test('chunker rejects an oversized grapheme without bisecting it', () {
    final section = TextSection(
      id: 's0',
      blocks: [TextBlock(id: 'p0', text: 'a${'\u0301' * 3001}')],
    );
    expect(() => narrationChunks(section), throwsFormatException);
  });

  group('Playback progress', () {
    late FakeNarrationApi api;
    late FakeNarrationPlayer player;
    late MemoryNarrationStore cache;
    late NarrationSession session;
    late TextPosition anchor;
    late List<TextPosition> commits;
    late CatalogBook book;
    late ReaderSettings preferences;
    double progress = 0;
    final sections = [
      const TextSection(
        id: 's0',
        blocks: [
          TextBlock(id: 'p0', text: 'First paragraph.'),
          TextBlock(id: 'p1', text: 'Second paragraph.'),
        ],
      ),
      const TextSection(
        id: 's1',
        blocks: [TextBlock(id: 'p2', text: 'Last paragraph.')],
      ),
    ];
    setUp(() async {
      api = FakeNarrationApi();
      player = FakeNarrationPlayer();
      cache = MemoryNarrationStore();
      book = testBook();
      anchor = sections.first.start;
      commits = [];
      preferences = const ReaderSettings();
      session = NarrationSession(
        api: api,
        preferences: () => preferences,
        player: player,
        store: cache,
        documents: MemoryDocumentStore(sections: sections),
        changed: () {},
        currentPosition: (_) => anchor,
        commit: (_, position, value) async {
          anchor = position;
          progress = value;
          commits.add(position);
        },
      );
      await session.consent(book);
    });
    tearDown(() => session.dispose());

    test('global preferences override legacy book values and mismatched voice offsets', () async {
      await session.detach(book);
      cache.manifests[book.hash] = NarrationManifest(
        account: 'account',
        cloudBookId: 'cloud-book',
        voice: 'cedar',
        speed: 2,
        anchor: anchor,
        chunkId: narrationChunks(sections.first).first.id,
        offsetMs: 7000,
      );
      preferences = const ReaderSettings(narrationSpeed: 1.5);
      await session.attach(book);
      await session.play();
      expect(session.manifest.voice, 'marin');
      expect(player.loadedOffset, Duration.zero);
      expect(player.multiplier, 1.5);
      expect(api.voices.first, 'marin');
    });

    test(
      'matching global voice retains legacy offset while global speed wins',
      () async {
        await session.detach(book);
        cache.manifests[book.hash] = NarrationManifest(
          account: 'account',
          cloudBookId: 'cloud-book',
          voice: 'cedar',
          speed: 2,
          anchor: anchor,
          chunkId: narrationChunks(sections.first).first.id,
          offsetMs: 7000,
        );
        preferences = const ReaderSettings(
          narrationVoice: 'cedar',
          narrationSpeed: .75,
        );
        await session.attach(book);
        await session.play();
        expect(player.loadedOffset, const Duration(seconds: 7));
        expect(player.multiplier, .75);
      },
    );

    test('global speed changes preserve playback offset and never generate new audio', () async {
      await session.play();
      await settle();
      player.position = const Duration(seconds: 8);
      final requests = api.requests.length;
      preferences = preferences.copyWith(narrationSpeed: 1.75);
      await session.applyPreferences(preferences);
      expect(player.playing, isTrue);
      expect(player.position, const Duration(seconds: 8));
      expect(player.multiplier, 1.75);
      expect(api.requests.length, requests);
      expect(commits, isEmpty);
    });

    test('voice switches while playing or paused discard old offsets and callbacks without generation', () async {
      await session.play();
      await settle();
      final token = player.token;
      final requests = api.requests.length;
      player.position = const Duration(seconds: 8);
      preferences = preferences.copyWith(narrationVoice: 'cedar');
      await session.applyPreferences(preferences);
      expect(player.playing, isFalse);
      expect(session.manifest.anchor, anchor);
      expect(session.manifest.chunkId, isNull);
      expect(session.manifest.offsetMs, 0);
      player.finish(token);
      await settle();
      expect(commits, isEmpty);
      expect(api.requests.length, requests);
      preferences = preferences.copyWith(narrationVoice: 'marin');
      await session.applyPreferences(preferences);
      expect(api.requests.length, requests);
      await session.play();
      expect(player.loadedOffset, Duration.zero);
      expect(api.requests.length, requests);
    });

    test('global voice changes fence buffering callbacks without requesting more audio', () async {
      api.gate = Completer<Uint8List>();
      final playing = session.play();
      await settle();
      preferences = preferences.copyWith(narrationVoice: 'cedar');
      await session.applyPreferences(preferences);
      expect(api.requests.length, 1);
      expect(session.status, NarrationStatus.paused);
      expect(session.manifest.offsetMs, 0);
      api.gate!.complete(testWav());
      await playing;
      expect(cache.files, isEmpty);
      expect(player.playing, isFalse);
      expect(commits, isEmpty);
      api.gate = null;
      await session.play();
      expect(api.voices.last, 'cedar');
    });

    test(
      'global voice defaults apply across books and reuse earlier voice cache',
      () async {
        await session.play();
        await settle();
        preferences = preferences.copyWith(
          narrationVoice: 'cedar',
          narrationSpeed: 1.5,
        );
        await session.applyPreferences(preferences);
        final second = CatalogBook(
          hash: 'b' * 64,
          fileName: 'Second.txt',
          path: '/Second.txt',
          title: 'Second',
          authors: const [],
          addedAt: DateTime.utc(2026),
        );
        cache.manifests[second.hash] = const NarrationManifest(
          account: 'account',
          cloudBookId: 'second',
          voice: 'marin',
          speed: .75,
        );
        await session.attach(second);
        expect(session.manifest.voice, 'cedar');
        expect(session.manifest.speed, 1.5);
        await session.attach(book);
        preferences = preferences.copyWith(narrationVoice: 'marin');
        await session.applyPreferences(preferences);
        final requests = api.requests.length;
        api.offline = true;
        await session.play();
        expect(session.status, NarrationStatus.playing);
        expect(api.requests.length, requests);
        expect(player.loadedOffset, Duration.zero);
      },
    );

    test(
      'clearing all caches fences downloads and retains consent and anchors',
      () async {
        api.gate = Completer<Uint8List>();
        final playing = session.play();
        await settle();
        final other = CatalogBook(
          hash: 'b' * 64,
          fileName: 'Other.txt',
          path: '/Other.txt',
          title: 'Other',
          authors: const [],
          addedAt: DateTime.utc(2026),
        );
        cache.manifests[other.hash] = NarrationManifest(
          account: 'account',
          cloudBookId: 'other',
          voice: 'cedar',
          anchor: anchor,
          chunkId: 'interrupted',
          offsetMs: 4321,
        );
        final clearing = session.clearAllCache([book, other]);
        await settle();
        api.gate!.complete(testWav());
        await playing;
        await clearing;
        expect(cache.files, isEmpty);
        expect(cache.manifests[book.hash]!.cloudBookId, 'cloud-book');
        expect(cache.manifests[book.hash]!.anchor, anchor);
        expect(cache.manifests[book.hash]!.chunkId, isNull);
        expect(cache.manifests[book.hash]!.offsetMs, 0);
        expect(cache.manifests[other.hash]!.cloudBookId, 'other');
        expect(cache.manifests[other.hash]!.voice, 'cedar');
        expect(cache.manifests[other.hash]!.anchor, anchor);
        expect(cache.manifests[other.hash]!.chunkId, isNull);
        expect(cache.manifests[other.hash]!.offsetMs, 0);
        expect(commits, isEmpty);
      },
    );

    test('theme-only preferences do not mutate native playback or narration sidecars', () async {
      await session.play();
      await settle();
      final saves = cache.saves;
      player.multiplier = 1.5;
      await session.applyPreferences(
        preferences.copyWith(theme: ReadingTheme.dark),
      );
      expect(cache.saves, saves);
      expect(player.multiplier, 1.5);
      expect(player.playing, isTrue);
    });

    test(
      'cache maintenance serializes voice changes and subsequent playback',
      () async {
        await session.play();
        await settle();
        cache.clearGate = Completer<void>();
        final clearing = session.clearAllCache([book]);
        await settle();
        preferences = preferences.copyWith(narrationVoice: 'cedar');
        final changing = session.applyPreferences(preferences);
        final playing = session.play();
        await settle();
        expect(session.manifest.voice, 'marin');
        expect(player.playing, isFalse);
        cache.clearGate!.complete();
        await clearing;
        await changing;
        await playing;
        expect(session.manifest.voice, 'cedar');
        expect(api.voices.last, 'cedar');
        expect(player.loadedOffset, Duration.zero);
      },
    );

    test(
      'cache maintenance finishes before navigation and deletion detach',
      () async {
        await session.play();
        await settle();
        cache.clearGate = Completer<void>();
        final clearing = session.clearAllCache([book]);
        await settle();
        var detached = false;
        final navigating = session.navigate(book);
        final deleting = session.detach(book).then((_) => detached = true);
        await settle();
        expect(detached, isFalse);
        cache.clearGate!.complete();
        await clearing;
        await navigating;
        await deleting;
        expect(session.book, isNull);
        expect(cache.files, isEmpty);
        expect(cache.manifests[book.hash]!.offsetMs, 0);
      },
    );

    test('generation and prefetch never advance progress; completion crosses chapters and finishes book', () async {
      await session.play();
      await settle();
      expect(api.requests.length, 2);
      expect(commits, isEmpty);
      expect(cache.pins.length, lessThanOrEqualTo(3));
      player.finish();
      await settle();
      expect(
        commits.single,
        const TextPosition(sectionId: 's0', blockId: 'p0', offset: 16),
      );
      player.finish();
      await settle();
      expect(commits.length, 2);
      expect(api.requests.last.start.sectionId, 's1');
      player.finish();
      await settle();
      expect(session.status, NarrationStatus.complete);
      expect(progress, 1);
      expect(commits.last.offset, 'Last paragraph.'.length);
    });
    test(
      'pause and restart restore exact audio offset without reading progress',
      () async {
        await session.play();
        player.position = const Duration(seconds: 7);
        await session.pause();
        expect(commits, isEmpty);
        expect(cache.manifests[book.hash]!.offsetMs, 7000);
        await session.play();
        expect(player.loadedOffset, const Duration(seconds: 7));
        await session.pause();
        await session.dispose();
        session = NarrationSession(
          api: api,
          player: FakeNarrationPlayer(),
          store: cache,
          documents: MemoryDocumentStore(sections: sections),
          changed: () {},
          currentPosition: (_) => anchor,
          commit: (_, _, _) async {},
        );
        await session.attach(book);
        await session.play();
        expect(
          (session.player as FakeNarrationPlayer).loadedOffset,
          const Duration(seconds: 7),
        );
      },
    );
    test('seeking to the ending cannot grant paragraph progress', () async {
      await session.play();
      await session.seek(const Duration(seconds: 30));
      player.finish();
      await settle();
      expect(commits, isEmpty);
      expect(session.status, NarrationStatus.paused);
      await session.play();
      expect(player.loadedOffset, Duration.zero);
    });
    test('navigation invalidates offset and stale completion; speed reuses files and voice generates anew', () async {
      await session.play();
      await settle();
      final old = player.token;
      await session.configure(speed: 2);
      expect(player.multiplier, 2);
      expect(api.requests.length, 2);
      player.position = const Duration(seconds: 8);
      await session.navigate(book);
      anchor = sections.last.start;
      player.finish(old);
      await settle();
      expect(commits, isEmpty);
      await session.play();
      expect(player.loadedOffset, Duration.zero);
      expect(api.requests.last.start.sectionId, 's1');
      await session.configure(voice: 'cedar');
      expect(player.playing, isFalse);
      await session.play();
      expect(api.voices.last, 'cedar');
    });
    test(
      'stop releases native audio before awaiting a suspended viewport frame',
      () async {
        await session.play();
        final restored = Completer<void>();
        session.restoreViewport = (_, _) => restored.future;
        final stopped = session.stop();
        await settle();
        expect(player.playing, isFalse);
        expect(player.token, isNull);
        expect(cache.pins, isEmpty);
        restored.complete();
        await stopped;
        expect(commits, isEmpty);
      },
    );

    test('cached speech plays offline and media pause preserves conservative progress', () async {
      await session.play();
      await settle();
      await session.pause();
      api.offline = true;
      await player.remotePlay!();
      expect(session.status, NarrationStatus.playing);
      await player.remotePause!();
      expect(session.status, NarrationStatus.paused);
      expect(commits, isEmpty);
    });
    test(
      'navigation rejects delayed audio without caching or resuming playback',
      () async {
        api.gate = Completer<Uint8List>();
        final playing = session.play();
        await settle();
        await session.navigate(book);
        api.gate!.complete(testWav());
        await playing;
        expect(cache.files, isEmpty);
        expect(player.playing, isFalse);
        expect(commits, isEmpty);
      },
    );
    test('deletion fences delayed downloads and completed callbacks', () async {
      api.gate = Completer<Uint8List>();
      final playing = session.play();
      await settle();
      final deleting = session.detach(book);
      await settle();
      api.gate!.complete(testWav());
      await playing;
      await deleting;
      expect(session.book, isNull);
      expect(cache.files, isEmpty);
      expect(commits, isEmpty);
    });
  });

  group('Private audio storage', () {
    late Directory root;
    late CatalogBook book;
    late FileNarrationStore store;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('reader_narration');
      final bytes = Uint8List.fromList(
        utf8.encode('First paragraph.\n\nLast paragraph.'),
      );
      book = (await BookImporter(root: root).import(
        ImportCandidate(
          name: 'Book.txt',
          size: bytes.length,
          readBytes: () async => bytes,
        ),
        {},
      )).book!;
      store = FileNarrationStore(root, maxBytes: testWav().length * 2);
    });
    tearDown(() => root.delete(recursive: true));
    test(
      'LRU evicts oldest unpinned audio and clearing preserves consent',
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
        offsetMs: 1234,
      );
      await store.save(book, value);
      final file = File(
        '${File(book.path).parent.path}/narration/manifest.json',
      );
      await file.rename('${file.path}.tmp');
      await file.writeAsString('{bad');
      expect((await store.load(book)).anchor, anchor);
      expect((await store.load(book)).offsetMs, 1234);
    });
  });
}
