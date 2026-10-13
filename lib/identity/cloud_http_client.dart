import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'cloud_book_fingerprint.dart';
import 'cloud_failure_kind.dart';
import 'cloud_identity.dart';
import 'cloud_service_exception.dart';

/// Shared authenticated REST transport with bounded, redirect-free responses.
class CloudHttpClient {
  /// Defaults to the narration deployment URL, falling back to illustrations.
  CloudHttpClient({required this.identity, http.Client? client, Uri? baseUri})
    : client = client ?? http.Client(),
      baseUri =
          baseUri ??
          Uri.parse(
            const String.fromEnvironment(
              'NARRATION_API_BASE_URL',
              defaultValue: String.fromEnvironment('ILLUSTRATION_API_BASE_URL'),
            ),
          );

  /// Shared native account session providing Auth and App Check headers.
  final CloudIdentity identity;

  /// Injectable request transport.
  final http.Client client;

  /// Public HTTPS service origin; no provider credentials enter the client.
  final Uri baseUri;

  static const _timeout = Duration(seconds: 30);

  /// Whether identity and a credential-free HTTPS origin are both available.
  bool get configured =>
      identity.configured &&
      baseUri.scheme == 'https' &&
      baseUri.host.isNotEmpty &&
      baseUri.userInfo.isEmpty &&
      !baseUri.hasQuery &&
      !baseUri.hasFragment;

  /// Sends one authenticated JSON request and decodes a bounded object body.
  ///
  /// Identity exceptions propagate unchanged; transport failures become
  /// [CloudServiceException]. A 404 returns `{}` when [missingIsSuccess].
  Future<Map<String, dynamic>> json(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool interactive = false,
    bool missingIsSuccess = false,
    int maxBytes = 64 * 1024,
  }) async {
    if (!configured) {
      throw const CloudServiceException(
        CloudFailureKind.notConfigured,
        'Cloud services are not configured in this build.',
      );
    }
    final headers = await identity.authorizationHeaders(
      interactive: interactive,
    );
    return _transport(() async {
      final request = http.Request(method, baseUri.resolve(path))
        ..headers.addAll(headers)
        ..followRedirects = false;
      if (body != null) request.body = jsonEncode(body);
      final response = await client.send(request).timeout(_timeout);
      final status = response.statusCode;
      if (status == 404 && missingIsSuccess) return <String, dynamic>{};
      final bytes = await _read(
        response,
        maxBytes,
        'Cloud service response exceeded its limit.',
      ).timeout(_timeout);
      if (status < 200 || status >= 300) {
        String? message;
        try {
          final decoded = jsonDecode(utf8.decode(bytes));
          if (decoded is Map && decoded['error'] is String) {
            message = decoded['error'] as String;
          }
        } on Object {
          // Keep the non-sensitive generic response for malformed errors.
        }
        throw CloudServiceException(
          CloudFailureKind.service,
          message ?? 'Cloud service error ($status).',
          statusCode: status,
        );
      }
      if (bytes.isEmpty) return <String, dynamic>{};
      Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        decoded = null;
      }
      if (decoded is! Map) {
        throw const CloudServiceException(
          CloudFailureKind.service,
          'Invalid cloud service response.',
        );
      }
      return decoded.cast<String, dynamic>();
    });
  }

  /// Account-scoped fingerprint of [hash], the only book identity any cloud
  /// registration sends; the import hash itself never leaves the device.
  ///
  /// A response without a key is a [CloudFailureKind.service] failure.
  Future<String> bookFingerprint(
    String hash, {
    required bool interactive,
  }) async {
    final json = await this.json(
      'GET',
      '/api/fingerprint-key',
      interactive: interactive,
    );
    final key = json['key'];
    if (key is! String) {
      throw const CloudServiceException(
        CloudFailureKind.service,
        'The server returned no book key.',
      );
    }
    return cloudBookFingerprint(hash, key);
  }

  /// Downloads a short-lived HTTPS asset without credentials, up to [maxBytes].
  ///
  /// Throws [CloudFailureKind.cancelled] once [isCurrent] turns false.
  Future<Uint8List> download(
    Uri uri, {
    required int maxBytes,
    bool Function()? isCurrent,
  }) async {
    if (uri.scheme != 'https' || uri.host.isEmpty) {
      throw const CloudServiceException(
        CloudFailureKind.service,
        'Invalid cloud download URL.',
      );
    }
    return _transport(() async {
      final request = http.Request('GET', uri)..followRedirects = false;
      final response = await client.send(request).timeout(_timeout);
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > maxBytes) {
        throw const CloudServiceException(
          CloudFailureKind.service,
          'Could not download cloud content.',
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final part in response.stream.timeout(_timeout)) {
        if (isCurrent != null && !isCurrent()) {
          throw const CloudServiceException(
            CloudFailureKind.cancelled,
            'Cloud download was cancelled.',
          );
        }
        if (bytes.length + part.length > maxBytes) {
          throw const CloudServiceException(
            CloudFailureKind.service,
            'Cloud download exceeded its limit.',
          );
        }
        bytes.add(part);
      }
      return bytes.takeBytes();
    });
  }

  Future<Uint8List> _read(
    http.StreamedResponse response,
    int maxBytes,
    String limitMessage,
  ) async {
    if ((response.contentLength ?? 0) > maxBytes) {
      throw CloudServiceException(CloudFailureKind.service, limitMessage);
    }
    final buffer = BytesBuilder(copy: false);
    await for (final part in response.stream) {
      if (buffer.length + part.length > maxBytes) {
        throw CloudServiceException(CloudFailureKind.service, limitMessage);
      }
      buffer.add(part);
    }
    return buffer.takeBytes();
  }

  Future<T> _transport<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on SocketException {
      throw const CloudServiceException(
        CloudFailureKind.offline,
        'Connect to the internet to use cloud features.',
      );
    } on http.ClientException {
      throw const CloudServiceException(
        CloudFailureKind.offline,
        'Connect to the internet to use cloud features.',
      );
    } on TimeoutException {
      throw const CloudServiceException(
        CloudFailureKind.timeout,
        'The cloud service timed out. Check your connection and retry.',
      );
    }
  }
}
