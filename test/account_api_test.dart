import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reader/account/account_usage.dart';
import 'package:reader/account/account_usage_exception.dart';
import 'package:reader/account/http_account_api.dart';
import 'package:reader/identity/cloud_identity_exception.dart';

import 'support/cloud_identity_fake.dart';

Map<String, dynamic> snapshot() => {
  'asOf': '2026-12-31T23:59:59.999Z',
  'narrationEnabled': false,
  'narrationMonthlyLimit': 500,
  'narrationRemaining': 350,
  'narrationResetAt': '2027-01-01T00:00:00.000Z',
  'illustrationsEnabled': false,
  'illustrationCreditsRemaining': null,
  'illustrationCreditsReserved': null,
};

/// Records protected reads and injects plugin failures without native SDK calls.
class Identity extends FakeCloudIdentity {
  bool? interactiveRequest;
  Object? failure;
  @override
  Future<Map<String, String>> authorizationHeaders({
    bool interactive = true,
  }) async {
    interactiveRequest = interactive;
    if (failure != null) throw failure!;
    return super.authorizationHeaders(interactive: interactive);
  }
}

void main() {
  test(
    'usage requests existing identity without sign-in or activation',
    () async {
      final identity = Identity();
      final api = HttpAccountApi(
        identity: identity,
        baseUri: Uri.parse('https://reader.example'),
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/v1/account/usage');
          expect(request.headers['x-firebase-appcheck'], 'test');
          return http.Response(jsonEncode(snapshot()), 200);
        }),
      );
      final result = await api.usage();
      expect(identity.interactiveRequest, false);
      expect(identity.signIns, 0);
      expect(result.narrationRemaining, 350);
      expect(result.narrationEnabled, false);
      expect(result.illustrationCreditsRemaining, isNull);
      expect(result.narrationResetAt, DateTime.utc(2027));
    },
  );
  test('usage rejects unsafe endpoint configuration', () {
    for (final url in [
      'http://reader.example',
      'https://secret@reader.example',
      'https://reader.example?token=secret',
      '',
    ]) {
      expect(
        HttpAccountApi(
          identity: Identity(),
          baseUri: Uri.parse(url),
        ).configured,
        false,
      );
    }
  });
  test(
    'snapshot rejects invalid balances, mixed activation, dates and flags',
    () {
      for (final changes in <Map<String, dynamic>>[
        {'narrationRemaining': 501},
        {'narrationMonthlyLimit': -1},
        {'narrationRemaining': 10.5},
        {'narrationEnabled': 'true'},
        {'narrationResetAt': '2027-02-01T00:00:00Z'},
        {'asOf': '2026-12-31'},
        {'illustrationCreditsReserved': 2},
      ]) {
        expect(
          () => AccountUsage.fromJson({...snapshot(), ...changes}),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'usage categorizes attestation failures without raw plugin details',
    () async {
      for (final failure in [
        const CloudIdentityException('Could not attest this app'),
        const CloudIdentityException(
          'Cloud generation requires macOS 14 or later',
        ),
        FirebaseException(
          plugin: 'firebase_app_check',
          message: 'secret token',
        ),
      ]) {
        final identity = Identity()..failure = failure;
        final api = HttpAccountApi(
          identity: identity,
          baseUri: Uri.parse('https://reader.example'),
        );
        await expectLater(
          api.usage(),
          throwsA(
            isA<AccountUsageException>()
                .having(
                  (error) => error.kind,
                  'kind',
                  AccountUsageFailureKind.attestation,
                )
                .having(
                  (error) => error.message.contains('secret'),
                  'safe message',
                  false,
                ),
          ),
        );
      }
    },
  );
  test(
    'usage distinguishes offline, authorization and malformed responses',
    () async {
      for (final entry in <(http.Client, AccountUsageFailureKind)>[
        (
          MockClient((_) async => throw http.ClientException('network')),
          AccountUsageFailureKind.offline,
        ),
        (
          MockClient((_) async => http.Response('{}', 401)),
          AccountUsageFailureKind.attestation,
        ),
        (
          MockClient((_) async => http.Response('malformed', 200)),
          AccountUsageFailureKind.service,
        ),
        (
          MockClient((_) async => http.Response('{}', 503)),
          AccountUsageFailureKind.service,
        ),
      ]) {
        final api = HttpAccountApi(
          identity: Identity(),
          baseUri: Uri.parse('https://reader.example'),
          client: entry.$1,
        );
        await expectLater(
          api.usage(),
          throwsA(
            isA<AccountUsageException>().having(
              (error) => error.kind,
              'kind',
              entry.$2,
            ),
          ),
        );
      }
    },
  );
  test('usage rejects oversized streamed responses without trusting content length', () async {
    final client = MockClient.streaming(
      (_, _) async => http.StreamedResponse(
        Stream.fromIterable([List.filled(64000, 32), List.filled(3000, 32)]),
        200,
      ),
    );
    final api = HttpAccountApi(
      identity: Identity(),
      baseUri: Uri.parse('https://reader.example'),
      client: client,
    );
    await expectLater(
      api.usage(),
      throwsA(
        isA<AccountUsageException>().having(
          (error) => error.kind,
          'kind',
          AccountUsageFailureKind.service,
        ),
      ),
    );
  });
}
