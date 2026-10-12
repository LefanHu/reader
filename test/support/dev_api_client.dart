import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Restores real sockets: the flutter_test binding answers every request from
/// the default [HttpOverrides] with 400.
class _NetworkHttpOverrides extends HttpOverrides {}

/// Plain real-network client for test-support REST calls that should not
/// appear in a test's [DevApiClient.exchanges] (token and account cleanup).
http.Client devNetworkClient() => IOClient(
  HttpOverrides.runWithHttpOverrides(HttpClient.new, _NetworkHttpOverrides()),
);

/// Runs real I/O in the root zone. Inside `testWidgets` the caller's fake
/// async zone would queue the socket's internal timers and microtasks until
/// fake time advances; root-zone work progresses on the real event loop and
/// only its result is delivered back to the caller's zone.
Future<T> onRealEventLoop<T>(Future<T> Function() action) =>
    Zone.root.run(action);

/// One logged round trip; [status] is null for an injected network loss.
class DevApiExchange {
  DevApiExchange(this.method, this.path, this.status, this.body);

  final String method;

  /// Path the caller requested, even when [DevApiClient.missingRoute] rewrote
  /// the request that reached dev.
  final String path;
  final int? status;

  /// UTF-8 response body; empty for injected failures and 204s.
  final String body;

  @override
  String toString() => '$method $path -> $status';
}

/// Holds one matching request before it is sent until [release].
class DevApiHold {
  DevApiHold._(this._matches);

  final bool Function(http.BaseRequest) _matches;
  final _started = Completer<void>();
  final _released = Completer<void>();

  /// Completes when the held request is waiting.
  Future<void> get started => _started.future;

  /// Lets the held request continue to dev.
  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

/// Real HTTP client for dev-API tests: logs exchanges, injects the faults dev
/// cannot produce on demand, and refuses routes that would spend money.
///
/// Paid routes enqueue provider work (OpenAI, image generation). They are
/// never sent; attempts are recorded in [blockedPaidRequests], which the
/// [create] teardown requires to be empty because production code may swallow
/// the thrown [StateError].
class DevApiClient extends http.BaseClient {
  DevApiClient._(this._inner);

  /// Creates a client whose teardown asserts no paid route was attempted and
  /// releases pending holds. Always use this factory.
  static DevApiClient create() {
    final client = DevApiClient._(devNetworkClient());
    addTearDown(() {
      client.close();
      expect(
        client.blockedPaidRequests,
        isEmpty,
        reason: 'test reached a paid route',
      );
    });
    return client;
  }

  static final _paidRoutes = [
    RegExp(r'^/api/books/[^/]+/chapters/\d+/jobs$'),
    RegExp(r'^/api/scenes/[^/]+/(unlock|regenerate)$'),
    RegExp(r'^/api/narration/books/[^/]+/jobs$'),
    RegExp(r'^/api/book-analysis/generations/[^/]+/(chunks/\d+|finalize)$'),
  ];

  static const _missingRoutePath = '/api/dev-api-test/missing-route';

  final http.Client _inner;

  /// Every completed or injected exchange, in completion order.
  final exchanges = <DevApiExchange>[];

  /// Paid POSTs that were refused without reaching dev.
  final blockedPaidRequests = <String>[];

  final _holds = <DevApiHold>[];
  final _allHolds = <DevApiHold>[];
  final _failures = <bool Function(http.BaseRequest)>[];
  final _missingRoutes = <bool Function(http.BaseRequest)>[];

  /// Holds the next request matching [matches] until released.
  DevApiHold hold(bool Function(http.BaseRequest) matches) {
    final hold = DevApiHold._(matches);
    _holds.add(hold);
    _allHolds.add(hold);
    return hold;
  }

  /// Fails the next matching request as a lost connection without sending it.
  /// Use only for offline cases; dev itself cannot be taken offline.
  void failNext(bool Function(http.BaseRequest) matches) =>
      _failures.add(matches);

  /// Sends the next matching request to an unknown route for a real 404.
  void missingRoute(bool Function(http.BaseRequest) matches) =>
      _missingRoutes.add(matches);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    if (request.method == 'POST' &&
        _paidRoutes.any((route) => route.hasMatch(path))) {
      blockedPaidRequests.add('POST $path');
      throw StateError('dev-api: blocked paid route POST $path');
    }
    if (_take(_failures, request) case final _?) {
      exchanges.add(DevApiExchange(request.method, path, null, ''));
      throw http.ClientException('dev-api: injected network loss', request.url);
    }
    var outgoing = request;
    if (_take(_missingRoutes, request) case final _?) {
      outgoing = _copy(
        request,
        request.url.replace(path: _missingRoutePath, query: null),
      );
    }
    final hold = _takeHold(request);
    if (hold != null) {
      hold._started.complete();
      await hold._released.future;
    }
    final (response, bytes) = await onRealEventLoop(() async {
      final response = await _inner.send(outgoing);
      return (response, await response.stream.toBytes());
    });
    exchanges.add(
      DevApiExchange(
        request.method,
        path,
        response.statusCode,
        utf8.decode(bytes, allowMalformed: true),
      ),
    );
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      contentLength: bytes.length,
      request: request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() {
    // A failed test must not leave a held request waiting forever.
    for (final hold in _allHolds) {
      hold.release();
    }
    _inner.close();
  }

  bool Function(http.BaseRequest)? _take(
    List<bool Function(http.BaseRequest)> matchers,
    http.BaseRequest request,
  ) {
    final index = matchers.indexWhere((matches) => matches(request));
    return index < 0 ? null : matchers.removeAt(index);
  }

  DevApiHold? _takeHold(http.BaseRequest request) {
    final index = _holds.indexWhere((hold) => hold._matches(request));
    return index < 0 ? null : _holds.removeAt(index);
  }

  static http.Request _copy(http.BaseRequest request, Uri url) {
    if (request is! http.Request) {
      throw StateError('dev-api: cannot rewrite ${request.runtimeType}');
    }
    return http.Request(request.method, url)
      ..headers.addAll(request.headers)
      ..followRedirects = request.followRedirects
      ..bodyBytes = request.bodyBytes;
  }
}
