import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/illustrations/book_text_index.dart';
import 'package:reader/illustrations/chapter_text_index.dart';
import 'package:reader/illustrations/file_illustration_store.dart';
import 'package:reader/illustrations/illustration_coordinator.dart';
import 'package:reader/illustrations/illustration_figure.dart';
import 'package:reader/illustrations/illustration_job_result.dart';
import 'package:reader/illustrations/illustration_manifest.dart';
import 'package:reader/illustrations/illustration_profile.dart';
import 'package:reader/illustrations/illustration_scene.dart';
import 'package:reader/illustrations/illustration_selection.dart';
import 'package:reader/illustrations/illustration_setup.dart';
import 'package:reader/illustrations/indexed_paragraph.dart';
import 'package:reader/illustrations/scene_anchor.dart';
import 'package:reader/illustrations/unlocked_illustration.dart';
import 'package:reader/text/text_position.dart';

import 'support/cloud_identity_fake.dart';
import 'support/fake_illustration_api.dart';
import 'support/fake_text_indexer.dart';
import 'support/illustration_image_fixture.dart';
import 'support/memory_cloud_deletion_outbox.dart';

const _sceneId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _anchor = SceneAnchor(
  href: 's0',
  spineOrdinal: 0,
  paragraphId: 'p1',
  cssSelector: 'body > p:nth-of-type(2)',
  fallbackProgression: .5,
);
const _before = TextPosition(sectionId: 's0', blockId: 'p1', offset: 5);
const _passed = TextPosition(sectionId: 's0', blockId: 'p1', offset: 6);
const _chapter = ChapterTextIndex(
  href: 's0',
  spineOrdinal: 0,
  title: null,
  paragraphs: [
    IndexedParagraph(
      id: 'p0',
      text: 'start',
      cssSelector: '',
      ordinal: 0,
      progression: 0,
    ),
    IndexedParagraph(
      id: 'p1',
      text: 'ending',
      cssSelector: '',
      ordinal: 1,
      progression: .5,
    ),
    IndexedParagraph(
      id: 'p2',
      text: 'after',
      cssSelector: '',
      ordinal: 2,
      progression: 1,
    ),
  ],
);
const _profile = IllustrationProfile(
  enabled: true,
  style: 'Ink',
  density: 3,
  providerId: 'openai',
  revision: 1,
  cloudBookId: 'cloud-book',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native image fixtures decode with landscape dimensions', () async {
    for (final bytes in [
      illustrationPng(),
      illustrationJpeg(),
      illustrationWebp(),
    ]) {
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 3);
        expect(frame.image.height, 2);
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    }
  });

  test('scene nullable fields explicitly clear and progress survives JSON', () {
    const scene = IllustrationScene(
      id: _sceneId,
      anchor: _anchor,
      state: IllustrationSceneState.hidden,
      localImagePath: 'original.png',
      localThumbnailPath: 'preview.webp',
      generationVersion: 1,
      regenerating: true,
      pendingGenerationVersion: 2,
      failureCategory: 'provider',
    );
    final restored = IllustrationScene.fromJson(scene.toJson());
    expect(restored.regenerating, isTrue);
    expect(restored.pendingGenerationVersion, 2);
    expect(restored.copyWith().failureCategory, 'provider');
    final cleared = restored.copyWith(
      regenerating: false,
      pendingGenerationVersion: null,
      failureCategory: null,
      localThumbnailPath: null,
    );
    expect(cleared.pendingGenerationVersion, isNull);
    expect(cleared.failureCategory, isNull);
    expect(cleared.localThumbnailPath, isNull);
    expect(cleared.localImagePath, 'original.png');
    expect(cleared.toJson().containsKey('pendingGenerationVersion'), isFalse);
  });

  test(
    'replacement downloads on the next poll and preserves hidden state',
    () async {
      final harness = await _Harness.create();
      harness.ready(2);
      final old = harness.scene;
      await harness.coordinator.advance(harness.book, _before);
      expect(harness.scene.generationVersion, 2);
      expect(harness.scene.pendingGenerationVersion, isNull);
      expect(harness.scene.regenerating, isFalse);
      expect(harness.scene.state, IllustrationSceneState.hidden);
      expect(harness.scene.localImagePath, endsWith('.v2.png'));
      expect(harness.scene.localThumbnailPath, endsWith('.v2.thumb.webp'));
      expect(
        await File(harness.scene.localImagePath!).readAsBytes(),
        illustrationPng(),
      );
      expect(
        await File(harness.scene.localThumbnailPath!).readAsBytes(),
        illustrationWebp(),
      );
      expect(await File(old.localImagePath!).exists(), isFalse);
      expect(await File(old.localThumbnailPath!).exists(), isFalse);
      expect(harness.book.lastPosition, _passed);
      await harness.reopen();
      expect(harness.scene.generationVersion, 2);
      expect(harness.scene.state, IllustrationSceneState.hidden);
    },
  );

  test('explicit regeneration keeps committed art and terminal failure clears progress', () async {
    final harness = await _Harness.create(
      state: IllustrationSceneState.unlocked,
    );
    final old = harness.scene;
    await harness.coordinator.regenerate(harness.book, old);
    expect(harness.api.regeneratedSceneIds, [_sceneId]);
    expect(harness.scene.state, IllustrationSceneState.unlocked);
    expect(harness.scene.regenerating, isTrue);
    expect(harness.scene.localImagePath, old.localImagePath);
    harness.remote(IllustrationSceneState.generating, 1, regenerating: true);
    await harness.coordinator.advance(harness.book, _before);
    expect(harness.scene.regenerating, isTrue);
    expect(harness.scene.generationVersion, 1);

    harness.remote(
      IllustrationSceneState.readyLocked,
      1,
      failureCategory: 'provider',
    );
    await harness.reopen();
    await harness.coordinator.advance(harness.book, _passed);
    expect(harness.scene.regenerating, isFalse);
    expect(harness.scene.pendingGenerationVersion, isNull);
    expect(harness.scene.failureCategory, 'provider');
    expect(harness.scene.generationVersion, 1);
    expect(harness.scene.localImagePath, old.localImagePath);
    expect(harness.scene.state, IllustrationSceneState.unlocked);
    expect(harness.api.unlockedSceneIds, isEmpty);
    expect(
      harness.coordinator.error,
      contains('previous artwork is still available'),
    );
    expect(await File(old.localImagePath!).readAsBytes(), illustrationPng());
    await harness.reopen();
    expect(harness.scene.regenerating, isFalse);
    expect(harness.scene.failureCategory, 'provider');
  });

  for (final failure in ['image', 'thumbnail', 'manifest']) {
    test(
      '$failure write failure retains committed art in memory and after restart',
      () async {
        final harness = await _Harness.create();
        final old = harness.scene;
        harness.ready(2);
        harness.store.failure = failure;
        await harness.coordinator.advance(harness.book, _passed);
        expect(harness.coordinator.error, isNotNull);
        expect(harness.scene.generationVersion, 1);
        expect(harness.scene.pendingGenerationVersion, 2);
        expect(harness.scene.localImagePath, old.localImagePath);
        expect(harness.scene.localThumbnailPath, old.localThumbnailPath);
        expect(
          await File(old.localImagePath!).readAsBytes(),
          illustrationPng(),
        );
        expect(
          await File(old.localThumbnailPath!).readAsBytes(),
          illustrationWebp(),
        );
        expect(harness.scene.state, IllustrationSceneState.hidden);

        harness.store.failure = null;
        await harness.reopen();
        expect(harness.scene.generationVersion, 1);
        expect(harness.scene.pendingGenerationVersion, 2);
        expect(harness.scene.localImagePath, old.localImagePath);
        // A process restart retries the pending version without deleting old art.
        await harness.coordinator.advance(harness.book, _passed);
        expect(harness.scene.generationVersion, 2);
        expect(harness.scene.pendingGenerationVersion, isNull);
        expect(await File(old.localImagePath!).exists(), isFalse);
        expect(await File(harness.scene.localImagePath!).exists(), isTrue);
      },
    );
  }

  test(
    'original preview alias saves one file and survives manifest recovery',
    () async {
      final harness = await _Harness.create();
      harness.ready(2, alias: true, jpeg: true);
      await harness.coordinator.advance(harness.book, _passed);
      expect(harness.store.savedVersionTwo, 1);
      expect(harness.scene.localImagePath, endsWith('.v2.jpg'));
      expect(harness.scene.localThumbnailPath, harness.scene.localImagePath);
      expect(
        await File(harness.scene.localImagePath!).readAsBytes(),
        illustrationJpeg(),
      );
      final file = File(
        '${File(harness.book.path).parent.path}/visuals/manifest.json',
      );
      await file.rename('${file.path}.bak');
      await file.writeAsString('{broken');
      await harness.reopen();
      expect(harness.scene.generationVersion, 2);
      expect(harness.scene.localThumbnailPath, harness.scene.localImagePath);
      await harness.coordinator.deleteScene(harness.book, harness.scene);
      expect(await harness.images.list().toList(), isEmpty);
    },
  );

  test(
    'poll and download preserve hide changes made while awaiting IO',
    () async {
      final api = _DelayedApi();
      final harness = await _Harness.create(
        state: IllustrationSceneState.unlocked,
        api: api,
      );
      harness.ready(2);
      api.pollStarted = Completer<void>();
      api.continuePoll = Completer<void>();
      api.unlockStarted = Completer<void>();
      api.continueUnlock = Completer<void>();
      final advance = harness.coordinator.advance(harness.book, _before);
      await api.pollStarted!.future;
      await harness.coordinator.hide(harness.book, harness.scene);
      api.continuePoll!.complete();
      await api.unlockStarted!.future;
      await harness.coordinator.unhide(harness.book, harness.scene);
      await harness.coordinator.hide(harness.book, harness.scene);
      api.continueUnlock!.complete();
      await advance;
      expect(harness.scene.generationVersion, 2);
      expect(harness.scene.state, IllustrationSceneState.hidden);
    },
  );

  for (final boundary in ['download', 'image', 'manifest']) {
    test(
      'scene deletion while $boundary is pending cannot resurrect artwork',
      () async {
        final api = _DelayedApi();
        final harness = await _Harness.create(api: api);
        harness.ready(2);
        final started = Completer<void>();
        final release = Completer<void>();
        if (boundary == 'download') {
          api.unlockStarted = started;
          api.continueUnlock = release;
        } else if (boundary == 'image') {
          harness.store.imageSaved = started;
          harness.store.continueImage = release;
        } else {
          harness.store.manifestSaved = started;
          harness.store.continueManifest = release;
        }
        final replacement = harness.coordinator.advance(harness.book, _passed);
        await started.future;
        await harness.coordinator.deleteScene(harness.book, harness.scene);
        release.complete();
        await replacement;
        expect(harness.coordinator.manifestFor(harness.book).scenes, isEmpty);
        expect(await harness.images.list().toList(), isEmpty);
        expect(harness.book.lastPosition, _passed);
        await harness.reopen();
        expect(harness.coordinator.manifestFor(harness.book).scenes, isEmpty);
      },
    );
  }

  test(
    'account cleanup while download is pending retains disabled consent',
    () async {
      final api = _DelayedApi();
      final harness = await _Harness.create(api: api);
      harness.ready(2);
      api.unlockStarted = Completer<void>();
      api.continueUnlock = Completer<void>();
      final replacement = harness.coordinator.advance(harness.book, _passed);
      await api.unlockStarted!.future;
      await harness.coordinator.clearLocalAccountData([harness.book]);
      api.continueUnlock!.complete();
      await replacement;
      expect(harness.coordinator.manifestFor(harness.book).enabled, isFalse);
      expect(harness.coordinator.manifestFor(harness.book).scenes, isEmpty);
      expect(await harness.images.list().toList(), isEmpty);
      await harness.reopen();
      expect(harness.coordinator.manifestFor(harness.book).enabled, isFalse);
    },
  );

  test(
    'stale completion cannot delete a competing committed generation',
    () async {
      final api = _DelayedApi();
      final harness = await _Harness.create(api: api);
      harness.ready(2);
      api.unlockStarted = Completer<void>();
      api.continueUnlock = Completer<void>();
      final replacement = harness.coordinator.advance(harness.book, _passed);
      await api.unlockStarted!.future;
      final image = await harness.store.saveImage(
        harness.book,
        _sceneId,
        illustrationJpeg(),
        mimeType: 'image/jpeg',
        generationVersion: 2,
      );
      final current = harness.coordinator
          .manifestFor(harness.book)
          .copyWith(
            scenes: [
              harness.scene.copyWith(
                generationVersion: 2,
                pendingGenerationVersion: null,
                localImagePath: image,
                localThumbnailPath: image,
              ),
            ],
          );
      await harness.store.saveManifest(harness.book, current);
      harness.coordinator.manifests[harness.book.hash] = current;
      api.continueUnlock!.complete();
      await replacement;
      expect(harness.scene.generationVersion, 2);
      expect(harness.scene.localImagePath, image);
      expect(await File(image).readAsBytes(), illustrationJpeg());
    },
  );

  test('new ready scene downloads without a reading gate', () async {
    final harness = await _Harness.create();
    await harness.coordinator.deleteScene(harness.book, harness.scene);
    harness.ready(1);
    await harness.coordinator.advance(harness.book, _before);
    expect(harness.scene.state, IllustrationSceneState.unlocked);
    expect(harness.scene.localImagePath, isNotNull);
    expect(harness.api.unlockedSceneIds, [_sceneId]);
    final figure = harness.coordinator.figuresFor(harness.book)['s0']!['p1']!;
    expect(figure.stage, IllustrationFigureStage.ready);
  });

  test(
    'a generating scene yields a generating figure and no download',
    () async {
      final harness = await _Harness.create();
      await harness.coordinator.deleteScene(harness.book, harness.scene);
      harness.remote(IllustrationSceneState.generating, 0);
      await harness.coordinator.advance(harness.book, _before);
      expect(harness.scene.localImagePath, isNull);
      expect(harness.api.unlockedSceneIds, isEmpty);
      expect(
        harness.coordinator.figuresFor(harness.book)['s0']!['p1']!.stage,
        IllustrationFigureStage.generating,
      );
    },
  );

  test(
    'a ready scene whose anchor cannot resolve is never downloaded',
    () async {
      final harness = await _Harness.create();
      await harness.coordinator.deleteScene(harness.book, harness.scene);
      harness.ready(1);
      harness.api.jobResults['job-0'] = IllustrationJobResult(
        id: 'job-0',
        status: 'complete',
        scenes: [
          IllustrationScene(
            id: _sceneId,
            jobId: 'job-0',
            anchor: const SceneAnchor(
              href: 's0',
              spineOrdinal: 0,
              paragraphId: 'missing',
              cssSelector: '',
              fallbackProgression: .5,
            ),
            state: IllustrationSceneState.readyLocked,
          ),
        ],
      );
      await harness.coordinator.advance(harness.book, _before);
      expect(harness.api.unlockedSceneIds, isEmpty);
      expect(harness.scene.state, IllustrationSceneState.readyLocked);
      expect(harness.scene.localImagePath, isNull);
    },
  );

  test('older ready polling cannot discard a pending replacement', () async {
    final harness = await _Harness.create();
    harness.ready(2);
    // A failed download leaves the replacement pending for a later retry.
    harness.store.failure = 'image';
    await harness.coordinator.advance(harness.book, _before);
    expect(harness.scene.pendingGenerationVersion, 2);
    harness.remote(IllustrationSceneState.readyLocked, 1);
    await harness.reopen();
    await harness.coordinator.advance(harness.book, _before);
    expect(harness.scene.pendingGenerationVersion, 2);
    expect(harness.scene.generationVersion, 1);
  });

  test('confirm saves server revision/current provider, retaining admitted jobs and art', () async {
    final harness = await _Harness.create();
    final old = harness.scene;
    harness.api.currentProfile = const IllustrationProfile(
      enabled: true,
      style: 'Ink',
      density: 3,
      providerId: 'google',
      revision: 4,
      cloudBookId: 'cloud-book',
    );
    await harness.coordinator.confirm(
      harness.book,
      setup: IllustrationSetup(
        cloudBookId: 'cloud-book',
        suggestedStyle: 'Watercolour',
        alternativeStyles: const [],
        estimatedCredits: 3,
        configuration: FakeIllustrationApi.configuration,
        currentProfile: harness.api.currentProfile,
      ),
      selection: const IllustrationSelection(
        style: 'Watercolour',
        providerId: 'google',
      ),
    );
    expect(harness.api.confirmedProfiles.single.providerId, 'google');
    expect(harness.api.confirmedProfiles.single.revision, 4);
    expect(harness.coordinator.manifestFor(harness.book).profile!.revision, 5);
    expect(harness.api.createdChapterOrdinals, isEmpty);
    expect(harness.scene.localImagePath, old.localImagePath);
    await harness.reopen();
    expect(
      harness.coordinator.manifestFor(harness.book).profile!.providerId,
      'google',
    );
    expect(harness.coordinator.manifestFor(harness.book).profile!.revision, 5);
  });

  test(
    'version deletion is scene-owned and ignores unrelated files and symlinks',
    () async {
      final harness = await _Harness.create();
      final other = 'b' * 40;
      final v2 = await harness.store.saveImage(
        harness.book,
        _sceneId,
        illustrationJpeg(),
        mimeType: 'image/jpeg',
        generationVersion: 2,
      );
      final otherPath = await harness.store.saveImage(
        harness.book,
        other,
        illustrationPng(),
        mimeType: 'image/png',
        generationVersion: 1,
      );
      final unrelated = File('${harness.images.path}/$_sceneId.v1.png.extra');
      await unrelated.writeAsString('not owned');
      final victim = File('${harness.root.path}/private.txt');
      await victim.writeAsString('private');
      final link = Link('${harness.images.path}/$_sceneId.v3.png');
      await link.create(victim.path);
      await harness.store.deleteSceneFiles(
        harness.book,
        _sceneId,
        generationVersion: 1,
      );
      expect(await File(v2).exists(), isTrue);
      expect(await File(otherPath).exists(), isTrue);
      expect(await unrelated.exists(), isTrue);
      await harness.store.deleteSceneFiles(harness.book, _sceneId);
      expect(await File(v2).exists(), isFalse);
      expect(await File(otherPath).exists(), isTrue);
      expect(await victim.readAsString(), 'private');
      expect(await link.exists(), isTrue);
      await expectLater(
        harness.store.saveImage(
          harness.book,
          _sceneId,
          illustrationPng(),
          mimeType: 'image/png',
          generationVersion: 3,
        ),
        throwsFormatException,
      );
      await expectLater(
        harness.store.saveImage(
          harness.book,
          _sceneId,
          illustrationPng(),
          mimeType: 'image/png',
          generationVersion: 0,
        ),
        throwsFormatException,
      );
      await expectLater(
        harness.store.saveImage(
          harness.book,
          _sceneId,
          illustrationPng(),
          mimeType: 'image/png',
          generationVersion: 4,
          thumbnail: true,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'image-directory links cannot redirect saves or scoped deletion',
    () async {
      final harness = await _Harness.create();
      final external = Directory('${harness.root.path}/external');
      await external.create();
      final victim = File('${external.path}/$_sceneId.v1.png');
      await victim.writeAsString('private');
      await harness.images.rename('${harness.images.path}-owned');
      await Link(harness.images.path).create(external.path);
      await expectLater(
        harness.store.saveImage(
          harness.book,
          _sceneId,
          illustrationPng(),
          mimeType: 'image/png',
          generationVersion: 2,
        ),
        throwsFormatException,
      );
      await expectLater(
        harness.store.deleteSceneFiles(harness.book, _sceneId),
        throwsFormatException,
      );
      expect(await victim.readAsString(), 'private');
    },
  );
}

class _Harness {
  _Harness(this.root, this.book, this.store, this.api);

  final Directory root;
  final CatalogBook book;
  final _FaultingStore store;
  final FakeIllustrationApi api;
  late IllustrationCoordinator coordinator;
  IllustrationScene get scene => coordinator.manifestFor(book).scenes.single;
  Directory get images =>
      Directory('${File(book.path).parent.path}/visuals/images');

  static Future<_Harness> create({
    IllustrationSceneState state = IllustrationSceneState.hidden,
    FakeIllustrationApi? api,
  }) async {
    final root = await Directory.systemTemp.createTemp(
      'illustration-lifecycle-',
    );
    addTearDown(() => root.delete(recursive: true));
    final hash = 'a' * 64;
    final owned = Directory('${root.path}/books/$hash');
    await owned.create(recursive: true);
    final source = File('${owned.path}/book.epub');
    await source.writeAsString('source book remains untouched');
    final book = CatalogBook(
      hash: hash,
      fileName: 'book.epub',
      path: source.path,
      title: 'Test',
      authors: const ['Author'],
      addedAt: DateTime.utc(2026),
      lastPosition: _passed,
    );
    final store = _FaultingStore(root);
    final image = await store.saveImage(
      book,
      _sceneId,
      illustrationPng(),
      mimeType: 'image/png',
      generationVersion: 1,
    );
    final thumbnail = await store.saveImage(
      book,
      _sceneId,
      illustrationWebp(),
      mimeType: 'image/webp',
      generationVersion: 1,
      thumbnail: true,
    );
    await store.saveIndex(
      book,
      BookTextIndex(bookHash: hash, chapters: const [_chapter]),
    );
    await store.saveManifest(
      book,
      IllustrationManifest(
        bookHash: hash,
        profile: _profile,
        chapterJobs: const {0: 'job-0'},
        scenes: [
          IllustrationScene(
            id: _sceneId,
            jobId: 'job-0',
            anchor: _anchor,
            state: state,
            localImagePath: image,
            localThumbnailPath: thumbnail,
            altText: 'Committed scene',
            caption: 'Committed caption',
          ),
        ],
      ),
    );
    final harness = _Harness(
      root,
      book,
      store,
      api ?? FakeIllustrationApi(configured: true),
    );
    await harness.reopen();
    return harness;
  }

  Future<void> reopen() async {
    coordinator = IllustrationCoordinator(
      store: store,
      textIndexer: FakeTextIndexer(chapters: const [_chapter]),
      api: api,
      identity: FakeCloudIdentity(),
      deletionOutbox: MemoryCloudDeletionOutbox(),
      currentBook: (_) => book,
      narrationOwnsPosition: (_) => false,
      refreshCloudAccount: () async {},
      changed: () {},
    );
    await coordinator.loadManifests([book]);
  }

  void remote(
    IllustrationSceneState state,
    int version, {
    bool regenerating = false,
    String? failureCategory,
  }) {
    api.jobResults['job-0'] = IllustrationJobResult(
      id: 'job-0',
      status: 'complete',
      scenes: [
        IllustrationScene(
          id: _sceneId,
          jobId: 'job-0',
          anchor: _anchor,
          state: state,
          generationVersion: version,
          regenerating: regenerating,
          failureCategory: failureCategory,
        ),
      ],
    );
  }

  void ready(int version, {bool alias = false, bool jpeg = false}) {
    remote(IllustrationSceneState.readyLocked, version);
    final bytes = jpeg ? illustrationJpeg() : illustrationPng();
    final mime = jpeg ? 'image/jpeg' : 'image/png';
    api.unlockedScenes[_sceneId] = UnlockedIllustration(
      image: bytes,
      thumbnail: alias ? bytes : illustrationWebp(),
      imageMimeType: mime,
      thumbnailMimeType: alias ? mime : 'image/webp',
      thumbnailUsesOriginal: alias,
      generationVersion: version,
      altText: 'Replacement scene',
      caption: 'Replacement caption',
    );
  }
}

class _FaultingStore extends FileIllustrationStore {
  _FaultingStore(super.root);
  String? failure;
  int savedVersionTwo = 0;
  Completer<void>? imageSaved;
  Completer<void>? continueImage;
  Completer<void>? manifestSaved;
  Completer<void>? continueManifest;

  @override
  Future<String> saveImage(
    CatalogBook book,
    String sceneId,
    Uint8List bytes, {
    required String mimeType,
    required int generationVersion,
    bool thumbnail = false,
  }) async {
    if (generationVersion == 2 && failure == 'thumbnail' && thumbnail) {
      throw const FileSystemException('Injected thumbnail write failure');
    }
    final path = await super.saveImage(
      book,
      sceneId,
      bytes,
      mimeType: mimeType,
      generationVersion: generationVersion,
      thumbnail: thumbnail,
    );
    if (generationVersion == 2) {
      savedVersionTwo++;
      if (failure == 'image' && !thumbnail) {
        throw const FileSystemException('Injected image publication failure');
      }
      if (!thumbnail && imageSaved != null) {
        imageSaved!.complete();
        await continueImage?.future;
        imageSaved = null;
      }
    }
    return path;
  }

  @override
  Future<void> saveManifest(
    CatalogBook book,
    IllustrationManifest manifest,
  ) async {
    final replacement = manifest.scenes.any(
      (scene) => scene.generationVersion == 2,
    );
    if (failure == 'manifest' && replacement) {
      throw const FileSystemException('Injected manifest write failure');
    }
    await super.saveManifest(book, manifest);
    if (replacement && manifestSaved != null) {
      manifestSaved!.complete();
      await continueManifest?.future;
      manifestSaved = null;
    }
  }
}

class _DelayedApi extends FakeIllustrationApi {
  _DelayedApi() : super(configured: true);
  Completer<void>? pollStarted;
  Completer<void>? continuePoll;
  Completer<void>? unlockStarted;
  Completer<void>? continueUnlock;

  @override
  Future<IllustrationJobResult> getJob(String jobId) async {
    final result = await super.getJob(jobId);
    pollStarted?.complete();
    await continuePoll?.future;
    return result;
  }

  @override
  Future<UnlockedIllustration> unlockScene(String sceneId) async {
    final result = await super.unlockScene(sceneId);
    unlockStarted?.complete();
    await continueUnlock?.future;
    return result;
  }
}
