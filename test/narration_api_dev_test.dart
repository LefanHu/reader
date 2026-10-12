@Timeout(Duration(minutes: 2))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/account/http_account_api.dart';
import 'package:reader/identity/cloud_service_exception.dart';
import 'package:reader/narration/http_narration_api.dart';

import 'fixtures/catalog_book.dart';
import 'support/dev_api_client.dart';
import 'support/dev_api_environment.dart';
import 'support/dev_api_identity.dart';

void main() {
  late DevApiIdentity identity;
  late DevApiClient client;
  late HttpNarrationApi api;

  setUpAll(() async => identity = await DevApiIdentity.shared());
  setUp(() {
    client = DevApiClient.create();
    api = HttpNarrationApi(
      identity: identity,
      client: client,
      baseUri: DevApiEnvironment.instance.baseUri,
    );
  });

  final narrationId = RegExp(r'^[a-f0-9]{64}$');

  test(
    'configuration is enabled with remaining within the monthly limit',
    () async {
      final configuration = await api.configuration();

      expect(configuration['enabled'], isTrue);
      expect(
        configuration['remaining'] as int,
        lessThanOrEqualTo(configuration['monthly'] as int),
      );
    },
  );

  test('each registration of the same book returns a distinct id', () async {
    final book = testBook();
    final first = await api.register(book);
    addTearDown(() => api.deleteBook(first.bookId));
    final second = await api.register(book);
    addTearDown(() => api.deleteBook(second.bookId));

    expect(first.bookId, matches(narrationId));
    expect(second.bookId, matches(narrationId));
    expect(second.bookId, isNot(first.bookId));
  });

  test('deleting registered and unknown books both succeed', () async {
    final registration = await api.register(testBook());

    await api.deleteBook(registration.bookId);
    await api.deleteBook('f' * 64);
  });

  test('registration after account deletion is rejected as gone', () async {
    final disposable = await DevApiIdentity.disposable();
    final baseUri = DevApiEnvironment.instance.baseUri;
    await HttpAccountApi(
      identity: disposable,
      client: client,
      baseUri: baseUri,
    ).deleteAccount();
    // Fresh same-uid tokens, since the Firebase user was deleted with them.
    await disposable.reauthenticate();
    final narration = HttpNarrationApi(
      identity: disposable,
      client: client,
      baseUri: baseUri,
    );

    await expectLater(
      narration.register(testBook()),
      throwsA(
        isA<CloudServiceException>().having(
          (error) => error.statusCode,
          'statusCode',
          410,
        ),
      ),
    );
  });
}
