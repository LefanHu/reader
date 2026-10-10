import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:http/http.dart' as http;

import '../identity/cloud_identity.dart';
import '../identity/cloud_identity_exception.dart';
import 'account_usage.dart';
import 'account_usage_exception.dart';
import 'api.dart';

/// Firebase/Auth and App Check protected read-only account REST boundary.
class HttpAccountApi implements AccountApi {
  /// Injectable identity and transport keep offline tests free of Firebase SDKs.
  HttpAccountApi({required this.identity, http.Client? client, Uri? baseUri})
    : client = client ?? http.Client(),
      baseUri =
          baseUri ??
          Uri.parse(
            const String.fromEnvironment(
              'NARRATION_API_BASE_URL',
              defaultValue: String.fromEnvironment('ILLUSTRATION_API_BASE_URL'),
            ),
          );

  /// Shared lazy native identity; this client never opens sign-in UI.
  final CloudIdentity identity;

  /// Injectable request transport.
  final http.Client client;

  /// Public HTTPS service origin; no provider credentials enter the client.
  final Uri baseUri;
  @override
  bool get configured =>
      identity.configured &&
      baseUri.scheme == 'https' &&
      baseUri.host.isNotEmpty &&
      baseUri.userInfo.isEmpty &&
      !baseUri.hasQuery &&
      !baseUri.hasFragment;

  @override
  Future<AccountUsage> usage() async {
    if (!configured) {
      throw const AccountUsageException(
        AccountUsageFailureKind.service,
        'Account usage is not configured in this build.',
      );
    }
    try {
      Map<String, String> headers;
      try {
        headers = await identity.authorizationHeaders(interactive: false);
      } on CloudIdentityException catch (error) {
        final attestation =
            error.message.toLowerCase().contains('attest') ||
            error.message.contains('macOS 14');
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
      }
      final request = http.Request('GET', baseUri.resolve('/v1/account/usage'))
        ..headers.addAll(headers)
        ..followRedirects = false;
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const AccountUsageException(
          AccountUsageFailureKind.attestation,
          'Account authentication or App Check could not be verified.',
        );
      }
      const limit = 64 * 1024;
      if (response.statusCode != 200 || (response.contentLength ?? 0) > limit) {
        throw const AccountUsageException(
          AccountUsageFailureKind.service,
          'Account usage is temporarily unavailable.',
        );
      }
      // Bound memory while streaming rather than trusting Content-Length or
      // materializing an arbitrarily large response before validating it.
      final bytes = await (() async {
        final buffer = BytesBuilder(copy: false);
        await for (final part in response.stream) {
          if (buffer.length + part.length > limit) {
            throw const AccountUsageException(
              AccountUsageFailureKind.service,
              'Account usage response exceeded its limit.',
            );
          }
          buffer.add(part);
        }
        return buffer.takeBytes();
      })().timeout(const Duration(seconds: 30));
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, dynamic>) {
        throw const FormatException('Invalid usage response.');
      }
      return AccountUsage.fromJson(json);
    } on AccountUsageException {
      rethrow;
    } on SocketException {
      throw const AccountUsageException(
        AccountUsageFailureKind.offline,
        'Connect to the internet to view account usage.',
      );
    } on http.ClientException {
      throw const AccountUsageException(
        AccountUsageFailureKind.offline,
        'Connect to the internet to view account usage.',
      );
    } on TimeoutException {
      throw const AccountUsageException(
        AccountUsageFailureKind.offline,
        'Account usage timed out. Check your connection and retry.',
      );
    } catch (_) {
      throw const AccountUsageException(
        AccountUsageFailureKind.service,
        'Account usage could not be loaded.',
      );
    }
  }
}
