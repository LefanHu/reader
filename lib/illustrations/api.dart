// DTO fields mirror the documented REST contract in this file.
// ignore_for_file: public_member_api_docs

import '../catalog/catalog_book.dart';
import 'chapter_text_index.dart';
import 'illustration_job_result.dart';
import 'illustration_profile.dart';
import 'illustration_setup.dart';
import 'unlocked_illustration.dart';

/// Authenticated API used by the reader; implementations never receive EPUBs.
abstract interface class IllustrationApi {
  /// User-triggered identity preparation before retrying old privacy requests.
  Future<void> signIn();
  bool get configured;

  /// Checks existing identity without opening a sign-in prompt.
  Future<bool> hasSession();
  Future<IllustrationSetup> registerBook(
    CatalogBook book, {
    required int chapterCount,
  });
  Future<void> confirmProfile(IllustrationProfile profile);
  Future<String> createChapterJob({
    required IllustrationProfile profile,
    required ChapterTextIndex chapter,
  });
  Future<IllustrationJobResult> getJob(String jobId);
  Future<UnlockedIllustration> unlockScene(String sceneId);
  Future<void> regenerateScene(String sceneId);
  Future<void> deleteScene(String sceneId);
  Future<void> deleteBook(String cloudBookId, {bool interactive = true});
  Future<void> signOut();
  Future<void> deleteAccount();
}
