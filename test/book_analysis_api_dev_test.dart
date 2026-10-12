@Timeout(Duration(minutes: 2))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/book_analysis/analysis_protocol.dart';
import 'package:reader/book_analysis/http_book_analysis_api.dart';
import 'package:reader/illustrations/http_illustration_api.dart';

import 'fixtures/analysis_manifest.dart';
import 'support/dev_api_books.dart';
import 'support/dev_api_client.dart';
import 'support/dev_api_environment.dart';
import 'support/dev_api_identity.dart';

void main() {
  late DevApiIdentity identity;
  late HttpBookAnalysisApi api;
  late HttpIllustrationApi illustrations;

  setUpAll(() async => identity = await DevApiIdentity.shared());
  setUp(() {
    final client = DevApiClient.create();
    final baseUri = DevApiEnvironment.instance.baseUri;
    api = HttpBookAnalysisApi(
      identity: identity,
      client: client,
      baseUri: baseUri,
    );
    illustrations = HttpIllustrationApi(
      identity: identity,
      client: client,
      baseUri: baseUri,
    );
  });

  test(
    'configuration accepts the pinned schema, analysis and model versions',
    () async {
      final configuration = await api.getConfiguration();

      expect(configuration.accountKey, matches(RegExp(r'^[a-f0-9]{64}$')));
    },
  );

  test('analysis registration shares the illustration cloud book id', () async {
    final book = devBook();
    final registration = await api.registerBook(book, sectionCount: 1);
    deleteDevBookAfterTest(illustrations, registration.bookId);

    final setup = await illustrations.registerBook(book, chapterCount: 1);

    expect(registration.bookId, setup.cloudBookId);
  });

  test('generation admission is idempotent and awaits the manifest', () async {
    final registration = await api.registerBook(devBook(), sectionCount: 1);
    deleteDevBookAfterTest(illustrations, registration.bookId);
    final manifest = analysisFixtureManifest();

    final first = await api.admitGeneration(manifest, registration.bookId);
    final second = await api.admitGeneration(manifest, registration.bookId);
    final progress = await api.getProgress(first.generationId);

    expect(second.generationId, first.generationId);
    expect(progress.status, AnalysisGenerationStatus.manifest);
  });
}
