import 'package:firebase_core/firebase_core.dart';
import 'package:http/http.dart' as http;

import '../identity/cloud_failure_kind.dart';
import '../identity/cloud_http_client.dart';
import '../identity/cloud_identity.dart';
import '../identity/cloud_identity_exception.dart';
import '../identity/cloud_service_exception.dart';
import 'account_usage.dart';
import 'account_usage_exception.dart';
import 'api.dart';

/// Firebase/Auth and App Check protected account REST boundary.
class HttpAccountApi implements AccountApi {
  /// Injectable identity and transport keep offline tests free of Firebase SDKs.
  HttpAccountApi({required this.identity, http.Client? client, Uri? baseUri})
    : _http = CloudHttpClient(
        identity: identity,
        client: client,
        baseUri: baseUri,
      );

  /// Shared lazy native identity; usage reads never open sign-in UI.
  final CloudIdentity identity;

  final CloudHttpClient _http;

  @override
  bool get configured => _http.configured;

  @override
  Future<AccountUsage> usage() async {
    if (!configured) {
      throw const AccountUsageException(
        AccountUsageFailureKind.service,
        'Account usage is not configured in this build.',
      );
    }
    try {
      final json = await _http.json('GET', '/v1/account/usage');
      return AccountUsage.fromJson(json);
    } on AccountUsageException {
      rethrow;
    } on CloudIdentityException catch (error) {
      final attestation = error.kind == CloudFailureKind.attestation;
      throw AccountUsageException(
        attestation
            ? AccountUsageFailureKind.attestation
            : AccountUsageFailureKind.service,
        attestation
            ? 'This installation could not verify App Check.'
            : 'Sign in again to view account usage.',
      );
    } on FirebaseException catch (error) {
      final attestation = error.plugin == 'firebase_app_check';
      throw AccountUsageException(
        attestation
            ? AccountUsageFailureKind.attestation
            : AccountUsageFailureKind.service,
        attestation
            ? 'This installation could not verify App Check.'
            : 'Account authentication could not be verified.',
      );
    } on CloudServiceException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        throw const AccountUsageException(
          AccountUsageFailureKind.attestation,
          'Account authentication or App Check could not be verified.',
        );
      }
      if (error.kind == CloudFailureKind.offline) {
        throw AccountUsageException(
          AccountUsageFailureKind.offline,
          error.message.contains('timed out')
              ? 'Account usage timed out. Check your connection and retry.'
              : 'Connect to the internet to view account usage.',
        );
      }
      throw const AccountUsageException(
        AccountUsageFailureKind.service,
        'Account usage is temporarily unavailable.',
      );
    } catch (_) {
      throw const AccountUsageException(
        AccountUsageFailureKind.service,
        'Account usage could not be loaded.',
      );
    }
  }

  @override
  Future<void> deleteAccount() async {
    await identity.reauthenticate();
    await _http.json('DELETE', '/v1/account');
    await identity.deleteAccount();
  }
}
