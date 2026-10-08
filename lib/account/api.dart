import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:http/http.dart' as http;

import '../cloud_identity.dart';

/// Server-observed account balances, including units held by pending generation.
class AccountUsage {
  /// Values are validated at the HTTP boundary; null credits mean not activated.
  const AccountUsage({
    required this.asOf,
    required this.narrationEnabled,
    required this.narrationMonthlyLimit,
    required this.narrationRemaining,
    required this.narrationResetAt,
    required this.illustrationsEnabled,
    required this.illustrationCreditsRemaining,
    required this.illustrationCreditsReserved,
  });

  /// UTC observation time; this snapshot is not a locally estimated balance.
  final DateTime asOf;

  /// Independent narration rollout state, not authentication availability.
  final bool narrationEnabled;

  /// Configured monthly UTF-16 input allowance.
  final int narrationMonthlyLimit;

  /// Unspent monthly units after submitted and reserved requests.
  final int narrationRemaining;

  /// First instant of the following UTC month.
  final DateTime narrationResetAt;

  /// Independent illustration rollout state.
  final bool illustrationsEnabled;

  /// Total unspent illustration credits; null means no credit initialization.
  final int? illustrationCreditsRemaining;

  /// Credits held by pending jobs; null accompanies an unactivated balance.
  final int? illustrationCreditsReserved;

  /// Rejects malformed balances rather than showing fabricated allowance.
  factory AccountUsage.fromJson(Map<String, dynamic> json) {
    int integer(String key) {
      final value = json[key];
      if (value is! int || value < 0 || value > 9007199254740991) {
        throw const FormatException('Invalid usage balance.');
      }
      return value;
    }

    bool flag(String key) {
      final value = json[key];
      if (value is! bool) throw const FormatException('Invalid feature state.');
      return value;
    }

    DateTime date(String key) {
      final value = json[key];
      final parsed = value is String && value.endsWith('Z')
          ? DateTime.tryParse(value)
          : null;
      if (parsed == null) {
        throw const FormatException('Invalid usage timestamp.');
      }
      return parsed.toUtc();
    }

    final limit = integer('narrationMonthlyLimit');
    final remaining = integer('narrationRemaining');
    final asOf = date('asOf');
    final reset = date('narrationResetAt');
    final expectedReset = DateTime.utc(asOf.year, asOf.month + 1);
    if (remaining > limit ||
        reset != expectedReset ||
        (json['illustrationCreditsRemaining'] == null) !=
            (json['illustrationCreditsReserved'] == null)) {
      throw const FormatException('Inconsistent usage snapshot.');
    }
    return AccountUsage(
      asOf: asOf,
      narrationEnabled: flag('narrationEnabled'),
      narrationMonthlyLimit: limit,
      narrationRemaining: remaining,
      narrationResetAt: reset,
      illustrationsEnabled: flag('illustrationsEnabled'),
      illustrationCreditsRemaining: json['illustrationCreditsRemaining'] == null
          ? null
          : integer('illustrationCreditsRemaining'),
      illustrationCreditsReserved: json['illustrationCreditsReserved'] == null
          ? null
          : integer('illustrationCreditsReserved'),
    );
  }
}

/// Recoverable transport categories used by Settings without exposing credentials.
enum AccountUsageFailureKind {
  /// Network unavailable or request timed out; retry preserves the session.
  offline,

  /// Protected requests could not obtain or verify installation attestation.
  attestation,

  /// Unconfigured endpoint, authentication expiry, or invalid service response.
  service,
}

/// Safe account status failure; never includes raw provider responses or tokens.
class AccountUsageException implements Exception {
  /// Carries a presentation category and a safe explanation.
  const AccountUsageException(this.kind, this.message);

  /// Allows distinct retry/attestation UI.
  final AccountUsageFailureKind kind;

  /// User-facing explanation, excluding credential details.
  final String message;
  @override
  String toString() => message;
}

/// Account reads require an existing session and never grant generation consent.
abstract interface class AccountApi {
  /// Whether public endpoint and native identity configuration are available.
  bool get configured;

  /// Returns a fresh server snapshot without initializing credits or generation.
  Future<AccountUsage> usage();
}

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
