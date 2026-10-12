import '../catalog/catalog_book.dart';
import 'analysis_protocol.dart';
import 'analysis_result.dart';
import 'analysis_source_models.dart';

/// Noninteractive preprocessing transport, independent of image generation.
abstract interface class BookAnalysisApi {
  /// Whether an authenticated service origin is configured.
  bool get configured;

  /// Reads the existing rollout and opaque account ownership fence.
  Future<AnalysisConfiguration> getConfiguration();

  /// Registers metadata only, without creating an image profile or credits.
  Future<AnalysisRegistration> registerBook(
    CatalogBook book, {
    required int sectionCount,
  });

  /// Admits a prose-free immutable generation identity.
  Future<AnalysisReceipt> admitGeneration(
    AnalysisSourceManifest manifest,
    String cloudBookId,
  );

  /// Uploads one bounded ordered coverage descriptor page.
  Future<void> putManifestPage(
    String generationId,
    int pageOrdinal,
    AnalysisDescriptorPage page,
  );

  /// Admits one exact normalized source window or adopts its prior intent.
  Future<AnalysisReceipt> submitChunk(
    String generationId,
    AnalysisChunkInput chunk,
  );

  /// Reads progress only; never dispatches work.
  Future<AnalysisProgress> getProgress(String generationId);

  /// Explicitly admits the next bounded reconciliation/indexing operation.
  Future<AnalysisReceipt> finalize(String generationId);

  /// Reads one owned immutable finalized result page.
  Future<AnalysisResultPage> getPage(String generationId, String pageId);
}
