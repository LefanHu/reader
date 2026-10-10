import 'dart:typed_data';

import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/illustrations/api.dart';
import 'package:reader/illustrations/chapter_text_index.dart';
import 'package:reader/illustrations/illustration_profile.dart';
import 'package:reader/illustrations/illustration_job_result.dart';
import 'package:reader/illustrations/illustration_setup.dart';
import 'package:reader/illustrations/unlocked_illustration.dart';

/// Offline illustration API used by tests that do not exercise cloud setup.
class FakeIllustrationApi implements IllustrationApi {
  FakeIllustrationApi({this.configured = false});

  @override
  final bool configured;
  bool session = true;
  @override
  Future<void> signIn() async => session = true;
  final deletedBooks = <String>[];
  @override
  Future<bool> hasSession() async => session;
  final List<int> createdChapterOrdinals = [];
  final List<String> unlockedSceneIds = [];
  final Map<String, IllustrationJobResult> jobResults = {};

  @override
  Future<void> confirmProfile(IllustrationProfile profile) async {}

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
    deletedBooks.add(cloudBookId);
  }

  @override
  Future<void> deleteAccount() async {}

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
  }) async => const IllustrationSetup(
    cloudBookId: 'cloud-book',
    suggestedStyle: 'Cinematic storybook realism',
    alternativeStyles: ['Expressive ink sketch'],
    estimatedCredits: 3,
  );

  @override
  Future<void> regenerateScene(String sceneId) async {}

  @override
  Future<void> signOut() async {}

  @override
  Future<UnlockedIllustration> unlockScene(String sceneId) async {
    unlockedSceneIds.add(sceneId);
    return UnlockedIllustration(
      image: Uint8List.fromList(const [1, 2, 3]),
      thumbnail: Uint8List.fromList(const [1, 2]),
      altText: 'A generated test scene',
      caption: 'A scene from the chapter',
      generationVersion: 1,
    );
  }
}
