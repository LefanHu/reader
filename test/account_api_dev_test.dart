@Timeout(Duration(minutes: 2))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/account/account_usage_exception.dart';
import 'package:reader/account/http_account_api.dart';
import 'package:reader/identity/cloud_service_exception.dart';
import 'package:reader/illustrations/http_illustration_api.dart';

import 'support/dev_api_books.dart';
import 'support/dev_api_client.dart';
import 'support/dev_api_environment.dart';
import 'support/dev_api_identity.dart';

void main() {
  late DevApiClient client;

  setUp(() => client = DevApiClient.create());

  HttpAccountApi accountApi(DevApiIdentity identity) => HttpAccountApi(
    identity: identity,
    client: client,
    baseUri: DevApiEnvironment.instance.baseUri,
  );

  HttpIllustrationApi illustrationApi(DevApiIdentity identity) =>
      HttpIllustrationApi(
        identity: identity,
        client: client,
        baseUri: DevApiEnvironment.instance.baseUri,
      );

  test(
    'usage of an account without books has no illustration credits',
    () async {
      final usage = await accountApi(await DevApiIdentity.disposable()).usage();

      expect(usage.illustrationCreditsRemaining, isNull);
      expect(usage.illustrationCreditsReserved, isNull);
      expect(
        usage.narrationRemaining,
        lessThanOrEqualTo(usage.narrationMonthlyLimit),
      );
    },
  );

  test('first book registration grants 100 unreserved credits', () async {
    final identity = await DevApiIdentity.disposable();
    await illustrationApi(identity).registerBook(devBook(), chapterCount: 1);

    final usage = await accountApi(identity).usage();

    expect(usage.illustrationCreditsRemaining, 100);
    expect(usage.illustrationCreditsReserved, 0);
  });

  test(
    'account deletion reauthenticates, deletes the user and tombstones the uid',
    () async {
      final identity = await DevApiIdentity.disposable();

      await accountApi(identity).deleteAccount();

      expect(identity.reauthentications, 1);
      expect(identity.deletions, 1);
      expect(identity.email, isNull);
      // Fresh same-uid tokens, since the Firebase user was deleted with them.
      await identity.reauthenticate();
      await expectLater(
        illustrationApi(identity).registerBook(devBook(), chapterCount: 1),
        throwsA(
          isA<CloudServiceException>().having(
            (error) => error.statusCode,
            'statusCode',
            410,
          ),
        ),
      );
    },
  );

  test('rejected App Check makes usage fail as attestation', () async {
    final identity = await DevApiIdentity.shared()
      ..rejectAppCheck = true;

    await expectLater(
      accountApi(identity).usage(),
      throwsA(
        isA<AccountUsageException>().having(
          (error) => error.kind,
          'kind',
          AccountUsageFailureKind.attestation,
        ),
      ),
    );
  });
}
