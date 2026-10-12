// Fake boundary behavior is documented at each owning type.
// ignore_for_file: public_member_api_docs
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/narration/file_narration_store.dart';
import 'package:reader/narration/narration_audio_asset.dart';
import 'package:reader/narration/narration_cache_key.dart';
import 'package:reader/narration/narration_cue.dart';
import 'package:reader/narration/narration_manifest.dart';
import 'package:reader/narration/narration_registration.dart';
import 'package:reader/narration/narration_timing.dart';
import 'package:reader/narration/session.dart';
import 'package:reader/narration/store.dart';
import 'package:reader/preferences/reader_settings.dart';
import 'package:reader/text/narration_chunk.dart';
import 'package:reader/text/narration_playback_unit.dart';
import 'package:reader/text/sentence_narration.dart';
import 'package:reader/text/text_position.dart';
import 'package:reader/text/text_section.dart';

import '../fixtures/narration_audio.dart';
import 'fake_narration_api.dart';
import 'fake_narration_player.dart';
import 'fixture_local_narration_source.dart';
import 'memory_document_store.dart';

/// A delayed file writer, not a simulation of native linguistic boundaries.
/// Cancellation settles the callback with stale success: the session's supplied
/// publication fence, rather than an early fixture exception, must reject it.
class LocalRenderGate {
  final started = Completer<void>();
  final _released = Completer<void>();
  String? stagingPath;
  bool cancelled = false;

  void release() {
    if (!_released.isCompleted) _released.complete();
  }

  void cancel() {
    cancelled = true;
    release();
  }
}

class LocalRenderRequest {
  LocalRenderRequest({
    required this.book,
    required this.profile,
    required this.unit,
    required this.generation,
    required this.key,
    required this.isCurrent,
    this.gate,
  });

  final CatalogBook book;
  final NarrationManifest profile;
  final NarrationPlaybackUnit unit;
  final int generation;
  final String key;
  final bool Function() isCurrent;
  final LocalRenderGate? gate;
  final finished = Completer<void>();
  NarrationAudioAsset? asset;
  Object? failure;

  NarrationTiming timing(List<NarrationCue> cues, {String? fingerprint}) =>
      NarrationTiming(
        audioKey: key,
        chunkId: unit.chunk.id,
        sourceDigest: unit.chunk.digest,
        synthesisFingerprint: fingerprint ?? profile.synthesisFingerprint,
        duration: const Duration(seconds: 1),
        cues: cues,
      );
}

/// Uses explicitly authored sentence pairs. These tests prove session behavior,
/// not Apple's tokenizer, marker production, or audible speech fidelity.
class ControlledLocalNarrationSource extends FixtureLocalNarrationSource {
  ControlledLocalNarrationSource(this.sentenceRanges);

  final Map<String, List<({int start, int end})>> sentenceRanges;
  final requests = <LocalRenderRequest>[];
  final cancelledGenerations = <int>[];
  final _gates = <TextPosition, LocalRenderGate>{};
  NarrationTiming? Function(LocalRenderRequest request)? timingFor;

  LocalRenderGate hold(TextPosition start) {
    final gate = LocalRenderGate();
    _gates[start] = gate;
    return gate;
  }

  @override
  Future<List<NarrationPlaybackUnit>> units(
    TextSection section, {
    TextPosition? from,
    String? language,
  }) async => sentenceNarrationUnits(
    section,
    sentenceRanges: sentenceRanges,
    from: from,
  );

  @override
  Future<NarrationAudioAsset> render(
    CatalogBook book,
    NarrationManifest profile,
    NarrationPlaybackUnit unit,
    NarrationStore store, {
    required int generation,
    required bool Function() isCurrent,
  }) async {
    if (!voices.any((voice) => voice.identifier == profile.voice)) {
      throw StateError('Choose an installed voice for new audio.');
    }
    renders++;
    final request = LocalRenderRequest(
      book: book,
      profile: profile,
      unit: unit,
      generation: generation,
      key: narrationCacheKey(
        book,
        profile,
        unit.chunk,
        sentence: unit.sentence,
      ),
      isCurrent: isCurrent,
      gate: _gates.remove(unit.chunk.start),
    );
    requests.add(request);
    try {
      final asset = await store.create(book, request.key, (path) async {
        await File(path).writeAsBytes(testWav(), flush: true);
        final gate = request.gate;
        if (gate != null) {
          gate.stagingPath = path;
          gate.started.complete();
          await gate._released.future;
        }
        return timingFor?.call(request);
      }, isCurrent: isCurrent);
      request.asset = asset;
      return asset;
    } on Object catch (failure) {
      request.failure = failure;
      rethrow;
    } finally {
      request.finished.complete();
    }
  }

  @override
  Future<void> cancel(int generation) async {
    cancelledGenerations.add(generation);
    for (final request in requests) {
      if (request.generation == generation) request.gate?.cancel();
    }
  }
}

/// Records even authentication/configuration reads, not only audio generation.
class ForbiddenLocalCloudApi extends FakeNarrationApi {
  final calls = <String>[];

  Never _unexpected(String operation) {
    calls.add(operation);
    throw StateError('Local narration crossed the cloud boundary: $operation');
  }

  @override
  bool get configured => _unexpected('configured');
  @override
  Future<Map<String, dynamic>> configuration() async =>
      _unexpected('configuration');
  @override
  Future<NarrationRegistration> register(CatalogBook book) async =>
      _unexpected('register');
  @override
  Future<Uint8List> audio(
    String bookId,
    NarrationChunk chunk,
    String voice, {
    required bool Function() isCurrent,
  }) async => _unexpected('audio');
  @override
  Future<void> deleteBook(String bookId) async => _unexpected('deleteBook');
}

class LocalNarrationSessionFixture {
  LocalNarrationSessionFixture._({
    required this.root,
    required this.book,
    required this.sections,
    required this.source,
    required this.store,
    required TextPosition anchor,
  }) : anchor = anchor {
    positions[book.hash] = anchor;
    player.length = const Duration(seconds: 1);
    session = NarrationSession(
      source: source,
      api: api,
      player: player,
      store: store,
      documents: MemoryDocumentStore(sections: sections),
      preferences: () => preferences,
      changed: _changed,
      isBookAvailable: (book) => !deleted.contains(book.hash),
      currentPosition: (book) => positions[book.hash],
      commit: (book, position, progress) async {
        positions[book.hash] = position;
        this.anchor = position;
        this.progress = progress;
        commits.add(position);
      },
    );
  }

  static Future<LocalNarrationSessionFixture> create({
    required List<TextSection> sections,
    Map<String, List<({int start, int end})>> sentenceRanges = const {},
    TextPosition? anchor,
  }) async {
    final root = await Directory.systemTemp.createTemp('reader_local_session_');
    try {
      final prose = sections
          .expand((section) => section.blocks)
          .map((block) => block.text)
          .join('\n\n');
      final book = await _ownedBook(root, prose, 'Local narration.txt');
      return LocalNarrationSessionFixture._(
        root: root,
        book: book,
        sections: sections,
        source: ControlledLocalNarrationSource(sentenceRanges),
        store: FileNarrationStore(root),
        anchor: anchor ?? sections.first.start,
      );
    } on Object {
      await root.delete(recursive: true);
      rethrow;
    }
  }

  static Future<CatalogBook> _ownedBook(
    Directory root,
    String prose,
    String name,
  ) async {
    final bytes = utf8.encode(prose);
    final hash = sha256.convert(bytes).toString();
    final directory = Directory('${root.path}/books/$hash');
    await directory.create(recursive: true);
    final path = '${directory.path}/book.txt';
    await File(path).writeAsBytes(bytes, flush: true);
    return CatalogBook(
      hash: hash,
      fileName: name,
      path: path,
      title: name,
      authors: const [],
      wordCount: 0,
      addedAt: DateTime.utc(2026),
    );
  }

  final Directory root;
  final CatalogBook book;
  final List<TextSection> sections;
  final ControlledLocalNarrationSource source;
  final FileNarrationStore store;
  final api = ForbiddenLocalCloudApi();
  final player = FakeNarrationPlayer();
  final commits = <TextPosition>[];
  final positions = <String, TextPosition>{};
  final deleted = <String>{};
  final _waiters = <Completer<void>>[];
  late final NarrationSession session;
  TextPosition anchor;
  double progress = 0;
  ReaderSettings preferences = const ReaderSettings(
    narrationVoice: FixtureLocalNarrationSource.firstVoice,
  );

  Future<CatalogBook> secondBook() async {
    final other = await _ownedBook(root, 'Different publication.', 'Other.txt');
    positions[other.hash] = sections.first.start;
    return other;
  }

  void _changed() {
    final waiting = _waiters.toList();
    _waiters.clear();
    for (final waiter in waiting) {
      waiter.complete();
    }
  }

  Future<void> until(bool Function() condition) async {
    while (!condition()) {
      final next = Completer<void>();
      _waiters.add(next);
      try {
        await next.future.timeout(const Duration(seconds: 5));
      } finally {
        _waiters.remove(next);
      }
    }
  }

  Future<void> dispose() async {
    try {
      await session.dispose();
      await Future.wait(
        source.requests.map((request) => request.finished.future),
      );
    } finally {
      if (await root.exists()) await root.delete(recursive: true);
    }
  }
}
