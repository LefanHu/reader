import 'dart:async';

import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/illustrations/api.dart';
import 'package:reader/illustrations/chapter_text_index.dart';
import 'package:reader/illustrations/illustration_configuration.dart';
import 'package:reader/illustrations/illustration_provider_option.dart';
import 'package:reader/illustrations/illustration_profile.dart';
import 'package:reader/illustrations/illustration_job_result.dart';
import 'package:reader/illustrations/illustration_setup.dart';
import 'package:reader/illustrations/unlocked_illustration.dart';

import 'illustration_image_fixture.dart';

/// Offline illustration API used by tests that do not exercise cloud setup.
class FakeIllustrationApi implements IllustrationApi {
  FakeIllustrationApi({this.configured = false});

  @override
  final bool configured;
  final deletedBooks = <String>[];

  /// When set, `deleteBook` waits for it before recording, modelling a slow purge.
  Completer<void>? deleteGate;
  final List<int> createdChapterOrdinals = [];
  final List<String> unlockedSceneIds = [];
  final Map<String, IllustrationJobResult> jobResults = {};
  IllustrationProfile? currentProfile;
  final List<IllustrationProfile> confirmedProfiles = [];
  final List<String> regeneratedSceneIds = [];
  final Map<String, UnlockedIllustration> unlockedScenes = {};

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
        model: 'text-image-diagnostic-v1',
        available: true,
        recommended: false,
        costTier: 'free',
      ),
    ],
  );

  @override
  Future<IllustrationConfiguration> getConfiguration() async => configuration;

  @override
  Future<IllustrationProfile> confirmProfile(
    IllustrationProfile profile,
  ) async {
    confirmedProfiles.add(profile);
    final existing = currentProfile;
    if (existing != null &&
        existing.providerId == profile.providerId &&
        existing.style == profile.style &&
        existing.density == profile.density &&
        existing.analysisVersion == profile.analysisVersion) {
      return existing;
    }
    if (profile.revision != (existing?.revision ?? 0)) {
      throw StateError('Illustration settings changed.');
    }
    final saved = IllustrationProfile(
      enabled: profile.enabled,
      style: profile.style,
      density: profile.density,
      providerId: profile.providerId,
      revision: (existing?.revision ?? 0) + 1,
      cloudBookId: profile.cloudBookId,
      analysisVersion: profile.analysisVersion,
    );
    currentProfile = saved;
    return saved;
  }

  @override
  Future<String> createChapterJob({
    required IllustrationProfile profile,
    required ChapterTextIndex chapter,
  }) async {
    createdChapterOrdinals.add(chapter.spineOrdinal);
    return 'job-${chapter.spineOrdinal}';
  }

  @override
  Future<void> deleteBook(String cloudBookId, {bool interactive = true}) async {
    await deleteGate?.future;
    deletedBooks.add(cloudBookId);
  }

  @override
  Future<void> deleteScene(String sceneId) async {}

  @override
  Future<IllustrationJobResult> getJob(String jobId) async =>
      jobResults[jobId] ??
      IllustrationJobResult(id: jobId, status: 'queued', scenes: const []);

  @override
  Future<IllustrationSetup> registerBook(
    CatalogBook book, {
    required int chapterCount,
  }) async => IllustrationSetup(
    cloudBookId: 'cloud-book',
    suggestedStyle: 'Cinematic storybook realism',
    alternativeStyles: ['Expressive ink sketch'],
    estimatedCredits: 3,
    configuration: configuration,
    currentProfile: currentProfile,
  );

  @override
  Future<void> regenerateScene(String sceneId) async {
    regeneratedSceneIds.add(sceneId);
  }

  @override
  Future<UnlockedIllustration> unlockScene(String sceneId) async {
    unlockedSceneIds.add(sceneId);
    return unlockedScenes[sceneId] ??
        UnlockedIllustration(
          image: illustrationPng(),
          thumbnail: illustrationWebp(),
          altText: 'A generated test scene',
          caption: 'A scene from the chapter',
          generationVersion: 1,
          imageMimeType: 'image/png',
          thumbnailMimeType: 'image/webp',
          thumbnailUsesOriginal: false,
        );
  }
}
