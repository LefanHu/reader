import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/illustrations/api.dart';
import 'package:reader/illustrations/chapter_text_index.dart';
import 'package:reader/illustrations/illustration_configuration.dart';
import 'package:reader/illustrations/illustration_exception.dart';
import 'package:reader/illustrations/illustration_job_result.dart';
import 'package:reader/illustrations/illustration_profile.dart';
import 'package:reader/illustrations/illustration_provider_option.dart';
import 'package:reader/illustrations/illustration_scene.dart';
import 'package:reader/illustrations/illustration_setup.dart';
import 'package:reader/illustrations/scene_anchor.dart';
import 'package:reader/illustrations/unlocked_illustration.dart';

import '../../test/support/illustration_image_fixture.dart';

/// Cloud-only replacement: native import, chapter indexing, disk, and decoding
/// stay real. Remote completion is gated by the scenario, never by UI methods.
class NativeIllustrationApi implements IllustrationApi {
  NativeIllustrationApi({this.publishInitialImages = true});

  @override
  bool get configured => true;

  final bool publishInitialImages;
  bool offline = false;

  /// While true, the scene is reported as still generating (no art to download).
  bool holdGeneration = false;
  bool rejectNextRegeneration = false;
  int registrations = 0;
  int configurations = 0;
  int polls = 0;
  final confirmations = <IllustrationProfile>[];
  final admissions = <NativeIllustrationAdmission>[];
  final regenerations = <IllustrationProfile>[];
  final unlocks = <String>[];
  IllustrationProfile? profile;
  final _jobs = <String, IllustrationScene>{};

  static const sceneId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  static const configuration = IllustrationConfiguration(
    enabled: true,
    defaultProviderId: 'openai',
    providers: [
      IllustrationProviderOption(
        id: 'openai',
        label: 'OpenAI',
        model: 'gpt-image-2.5-flare',
        available: true,
        recommended: false,
        costTier: 'balanced',
      ),
      IllustrationProviderOption(
        id: 'google',
        label: 'Google',
        model: 'gemini-nano-banana-2.1',
        available: true,
        recommended: true,
        costTier: 'balanced',
      ),
      IllustrationProviderOption(
        id: 'seedream',
        label: 'ByteDance',
        model: 'seedream-4-0-250828',
        available: true,
        recommended: false,
        costTier: 'budget',
      ),
      IllustrationProviderOption(
        id: 'qwen',
        label: 'Alibaba',
        model: 'qwen-image-3.0',
        available: true,
        recommended: false,
        costTier: 'budget',
      ),
      IllustrationProviderOption(
        id: 'xai',
        label: 'xAI',
        model: 'grok-imagine-image-2.0',
        available: true,
        recommended: false,
        costTier: 'balanced',
      ),
      IllustrationProviderOption(
        id: 'flux',
        label: 'BFL',
        model: 'flux-3-image',
        available: true,
        recommended: false,
        costTier: 'premium',
      ),
      IllustrationProviderOption(
        id: 'diagnostic',
        label: 'Pipeline test',
        model: 'text-image-diagnostic',
        available: true,
        recommended: false,
        costTier: 'free',
      ),
    ],
  );

  void _connected() {
    if (offline) {
      throw const IllustrationException('Illustration service is offline.');
    }
  }

  @override
  Future<IllustrationConfiguration> getConfiguration() async {
    _connected();
    configurations++;
    return configuration;
  }

  @override
  Future<IllustrationSetup> registerBook(
    CatalogBook book, {
    required int chapterCount,
  }) async {
    _connected();
    registrations++;
    return IllustrationSetup(
      cloudBookId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      suggestedStyle: 'Cinematic storybook realism',
      alternativeStyles: const ['Expressive ink sketch'],
      estimatedCredits: chapterCount * 3,
      configuration: configuration,
      currentProfile: profile,
    );
  }

  @override
  Future<IllustrationProfile> confirmProfile(
    IllustrationProfile proposed,
  ) async {
    _connected();
    final saved = profile;
    if (saved != null &&
        saved.style == proposed.style &&
        saved.providerId == proposed.providerId &&
        saved.density == proposed.density) {
      return saved;
    }
    if (proposed.revision != (saved?.revision ?? 0)) {
      throw const IllustrationException(
        'Illustration settings changed. Reopen settings.',
      );
    }
    final confirmed = IllustrationProfile(
      enabled: proposed.enabled,
      cloudBookId: proposed.cloudBookId,
      style: proposed.style,
      providerId: proposed.providerId,
      revision: (saved?.revision ?? 0) + 1,
      density: proposed.density,
    );
    profile = confirmed;
    confirmations.add(confirmed);
    return confirmed;
  }

  @override
  Future<String> createChapterJob({
    required IllustrationProfile profile,
    required ChapterTextIndex chapter,
  }) async {
    _connected();
    final id = 'native-job-${chapter.spineOrdinal}-r${profile.revision}';
    admissions.add(NativeIllustrationAdmission(id, profile, chapter));
    // One deterministic scene is sufficient to exercise real spoiler/reveal
    // and replacement storage, without introducing unrelated chapter artwork.
    if (chapter.spineOrdinal == 0) {
      final paragraph = chapter.paragraphs.first;
      _jobs[id] = IllustrationScene(
        id: sceneId,
        jobId: id,
        anchor: SceneAnchor(
          href: chapter.href,
          spineOrdinal: chapter.spineOrdinal,
          paragraphId: paragraph.id,
          fallbackProgression: paragraph.progression,
        ),
        state: IllustrationSceneState.readyLocked,
      );
    }
    return id;
  }

  @override
  Future<IllustrationJobResult> getJob(String jobId) async {
    _connected();
    polls++;
    final stored = _jobs[jobId];
    final held = holdGeneration && stored != null;
    final scene = held
        ? stored.copyWith(state: IllustrationSceneState.generating)
        : stored;
    return IllustrationJobResult(
      id: jobId,
      status: held
          ? 'analyzing'
          : publishInitialImages
          ? 'complete'
          : 'queued',
      scenes: scene == null || !publishInitialImages ? const [] : [scene],
    );
  }

  @override
  Future<UnlockedIllustration> unlockScene(String id) async {
    _connected();
    unlocks.add(id);
    final scene = _jobs.values.firstWhere((scene) => scene.id == id);
    if (scene.regenerating ||
        scene.state != IllustrationSceneState.readyLocked) {
      throw const IllustrationException('The replacement is not ready.');
    }
    final replacement = scene.generation > 1;
    final original = replacement ? illustrationJpeg() : illustrationPng();
    final alias = replacement && regenerations.last.providerId == 'flux';
    final mime = replacement ? 'image/jpeg' : 'image/png';
    return UnlockedIllustration(
      image: original,
      thumbnail: alias ? original : illustrationWebp(),
      imageMimeType: mime,
      thumbnailMimeType: alias ? mime : 'image/webp',
      thumbnailUsesOriginal: alias,
      altText: 'Native fixture landscape version ${scene.generation}',
      caption: 'The quiet room, version ${scene.generation}',
      generation: scene.generation,
    );
  }

  @override
  Future<void> regenerateScene(String id) async {
    _connected();
    if (rejectNextRegeneration) {
      rejectNextRegeneration = false;
      throw const IllustrationException(
        'Could not submit replacement. Try again.',
      );
    }
    regenerations.add(profile!);
    final entry = _jobs.entries.firstWhere((entry) => entry.value.id == id);
    _jobs[entry.key] = entry.value.copyWith(
      state: IllustrationSceneState.generating,
      regenerating: true,
      failureCategory: null,
    );
  }

  /// Completes the remote operation; actual Reader idle polling commits it.
  void finishRegeneration({required bool success}) {
    final entry = _jobs.entries.firstWhere((entry) => entry.value.regenerating);
    _jobs[entry.key] = entry.value.copyWith(
      state: success
          ? IllustrationSceneState.readyLocked
          : IllustrationSceneState.failed,
      regenerating: false,
      generation: entry.value.generation + (success ? 1 : 0),
      failureCategory: success ? null : 'generation_failed',
    );
  }

  @override
  Future<void> deleteScene(String sceneId) async {
    _connected();
    _jobs.removeWhere((_, scene) => scene.id == sceneId);
  }

  @override
  Future<void> deleteBook(String cloudBookId, {bool interactive = true}) async {
    _connected();
    _jobs.clear();
    profile = null;
  }
}

/// Admission retains normalized chapter text and its original profile snapshot.
class NativeIllustrationAdmission {
  const NativeIllustrationAdmission(this.id, this.profile, this.chapter);
  final String id;
  final IllustrationProfile profile;
  final ChapterTextIndex chapter;
}
