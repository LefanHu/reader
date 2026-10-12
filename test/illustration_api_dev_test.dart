@Timeout(Duration(minutes: 2))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/identity/cloud_service_exception.dart';
import 'package:reader/illustrations/http_illustration_api.dart';
import 'package:reader/illustrations/illustration_profile.dart';

import 'support/dev_api_books.dart';
import 'support/dev_api_client.dart';
import 'support/dev_api_environment.dart';
import 'support/dev_api_identity.dart';

void main() {
  late DevApiIdentity identity;
  late HttpIllustrationApi api;

  setUpAll(() async => identity = await DevApiIdentity.shared());
  setUp(
    () => api = HttpIllustrationApi(
      identity: identity,
      client: DevApiClient.create(),
      baseUri: DevApiEnvironment.instance.baseUri,
    ),
  );

  IllustrationProfile profile(String id, String style, int revision) =>
      IllustrationProfile(
        enabled: true,
        style: style,
        density: 3,
        providerId: 'diagnostic',
        revision: revision,
        cloudBookId: id,
      );

  test('configuration lists the production and diagnostic sources', () async {
    final configuration = await api.getConfiguration();

    expect(
      configuration.providers.map((provider) => provider.id),
      containsAll(['openai', 'diagnostic']),
    );
  });

  test(
    'registration is stable for the same book and estimates credits',
    () async {
      final book = devBook();
      final first = await api.registerBook(book, chapterCount: 2);
      deleteDevBookAfterTest(api, first.cloudBookId!);
      final second = await api.registerBook(book, chapterCount: 2);

      expect(first.cloudBookId, matches(RegExp(r'^[a-f0-9]{40}$')));
      expect(first.estimatedCredits, 6);
      expect(second.cloudBookId, first.cloudBookId);
    },
  );

  test('profile revisions are idempotent and reject stale writes', () async {
    final setup = await api.registerBook(devBook(), chapterCount: 1);
    final id = setup.cloudBookId!;
    deleteDevBookAfterTest(api, id);

    final saved = await api.confirmProfile(profile(id, 'Ink', 0));
    final repeated = await api.confirmProfile(profile(id, 'Ink', 0));

    expect(saved.revision, 1);
    expect(repeated.revision, 1);
    await expectLater(
      api.confirmProfile(profile(id, 'Watercolour', 0)),
      throwsA(
        isA<CloudServiceException>().having(
          (error) => error.statusCode,
          'statusCode',
          409,
        ),
      ),
    );
  });

  test('deleted books are purged and re-register without a profile', () async {
    final book = devBook();
    final setup = await api.registerBook(book, chapterCount: 1);
    final id = setup.cloudBookId!;
    deleteDevBookAfterTest(api, id);
    await api.confirmProfile(profile(id, 'Ink', 0));

    await api.deleteBook(id);
    final revived = await api.registerBook(book, chapterCount: 1);

    expect(revived.cloudBookId, id);
    expect(revived.currentProfile, isNull);
  });

  test('deleting a never-registered book succeeds', () async {
    await api.deleteBook('e' * 40);
  });
}
