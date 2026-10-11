import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reader/account/account_usage.dart';
import 'package:reader/account/account_usage_exception.dart';
import 'package:reader/account/api.dart';
import 'package:reader/account/http_account_api.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/app/reader_controller.dart';
import 'package:reader/narration/api.dart';
import 'package:reader/narration/http_narration_api.dart';
import 'package:reader/narration/player.dart';
import 'package:reader/narration/session.dart';
import 'package:reader/narration/store.dart';
import 'package:reader/preferences/library_filter.dart';
import 'package:reader/preferences/library_sort.dart';
import 'package:reader/preferences/reader_settings.dart';
import 'package:reader/preferences/reading_theme.dart';
import 'package:reader/text/document_store.dart';
import 'package:reader/text/text_position.dart';

import 'fixtures/catalog_book.dart';
import 'support/memory_document_store.dart';
import 'support/memory_settings_store.dart';
import 'fixtures/account_usage.dart';
import 'support/fake_account_api.dart';
import 'support/cloud_identity_fake.dart';
import 'support/fake_narration_api.dart';
import 'support/fake_narration_player.dart';
import 'support/memory_narration_store.dart';
import 'support/test_controller.dart';

/// Holds the first complete preference write to expose ordering regressions.
class _DelayedSettingsStore extends MemorySettingsStore {
  _DelayedSettingsStore([super.initial]);
  final firstWrite = Completer<void>();
  int writes = 0;
  @override
  Future<void> save(ReaderSettings value) async {
    writes++;
    if (writes == 1) await firstWrite.future;
    await super.save(value);
  }
}

/// Exposes a local failure after the server and Firebase deletion have committed.
class _FailingClearStore extends MemoryNarrationStore {
  @override
  Future<void> clear(CatalogBook book) async {
    throw StateError('Local audio cleanup failed.');
  }
}

Future<ReaderController> _controller({
  AccountApi? api,
  FakeCloudIdentity? identity,
  MemorySettingsStore? settingsStore,
  NarrationApi? narrationApi,
  NarrationPlayer? narrationPlayer,
  NarrationStore? narrationStore,
  TextDocumentStore? narrationDocuments,
  bool disposeOnTeardown = true,
}) async {
  final controller = await testController(
    books: [testBook()],
    settingsStore: settingsStore,
    accountApi: api,
    cloudIdentity: identity,
    narrationApi: narrationApi,
    narrationPlayer: narrationPlayer,
    narrationStore: narrationStore,
    narrationDocuments: narrationDocuments,
  );
  await controller.refreshCloudAccount();
  addTearDown(() async {
    if (disposeOnTeardown) controller.dispose();
    await controller.flush();
  });
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'queued preference writes retain changes to independent controls',
    () async {
      final store = _DelayedSettingsStore();
      final controller = await _controller(settingsStore: store);
      final first = controller.preferences.configure(
        libraryFilter: LibraryFilter.reading,
      );
      final second = controller.preferences.configure(fontSize: 125);
      await Future<void>.delayed(Duration.zero);
      expect(store.writes, 1);
      store.firstWrite.complete();
      await Future.wait([first, second]);
      expect(store.settings.libraryFilter, LibraryFilter.reading);
      expect(store.settings.fontSize, 125);
    },
  );

  test('startup replaces a saved Apple voice with the cloud default', () async {
    final store = MemorySettingsStore(
      const ReaderSettings(
        narrationVoice: 'apple:com.apple.voice.compact.en-US.Samantha',
      ),
    );
    final controller = await _controller(settingsStore: store);
    expect(controller.preferences.settings.narrationVoice, 'marin');
    expect(store.settings.narrationVoice, 'marin');
  });

  test('startup keeps a saved cloud voice', () async {
    final store = MemorySettingsStore(
      const ReaderSettings(narrationVoice: 'cedar'),
    );
    final controller = await _controller(settingsStore: store);
    expect(controller.preferences.settings.narrationVoice, 'cedar');
  });

  test(
    'reset restores global preferences and retains books and identity',
    () async {
      final identity = FakeCloudIdentity()..email = 'reader@example.test';
      final controller = await _controller(identity: identity);
      final position = controller.catalog.books.single.lastPosition;
      await controller.preferences.configure(
        theme: ReadingTheme.dark,
        narrationVoice: 'cedar',
        narrationSpeed: 1.75,
        librarySort: LibrarySort.title,
      );
      await controller.preferences.reset();
      expect(
        controller.preferences.settings.toJson(),
        const ReaderSettings().toJson(),
      );
      expect(controller.catalog.books.single.lastPosition, position);
      expect(controller.cloudEmail, 'reader@example.test');
      expect(identity.signOuts, 0);
    },
  );

  test('reset during playback retains registration and anchors and waits for preference persistence', () async {
    final preferences = _DelayedSettingsStore(
      const ReaderSettings(narrationVoice: 'cedar', narrationSpeed: 1.75),
    );
    final api = FakeNarrationApi();
    final player = FakeNarrationPlayer();
    final cache = MemoryNarrationStore();
    final controller = await _controller(
      settingsStore: preferences,
      narrationApi: api,
      narrationPlayer: player,
      narrationStore: cache,
      narrationDocuments: MemoryDocumentStore(),
    );
    addTearDown(() {
      if (!preferences.firstWrite.isCompleted) {
        preferences.firstWrite.complete();
      }
    });
    const anchor = TextPosition(
      version: 1,
      sectionId: 's0',
      blockId: 'p1',
      offset: 2,
    );
    await controller.savePosition(controller.catalog.books.single, anchor, .3);
    final book = controller.catalog.books.single;
    await controller.registerNarration(book);
    final session = controller.narration!;
    await session.play();
    expect(session.status, NarrationStatus.playing);
    expect(player.multiplier, 1.75);
    expect(api.voices, everyElement('cedar'));
    player.position = const Duration(seconds: 7);
    await session.flush();
    expect(session.manifest.offsetMs, 7000);
    final token = player.token!;
    final requests = api.requests.length;
    final files = Map.of(cache.files);

    final reset = controller.preferences.reset();
    for (var turn = 0; turn < 20 && preferences.writes == 0; turn++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(preferences.writes, 1);
    expect(session.status, NarrationStatus.paused);
    expect(player.playing, false);
    expect(player.multiplier, 1);
    expect(session.manifest.voice, 'marin');
    expect(session.manifest.chunkId, isNull);
    expect(session.manifest.offsetMs, 0);
    expect(session.manifest.cloudBookId, 'cloud-book');
    expect(session.manifest.anchor, anchor);
    expect(cache.files, files);
    expect(api.requests.length, requests);

    // A native completion from the old voice cannot advance the shared anchor.
    player.finish(token);
    var flushed = false;
    final flush = controller.flush().then((_) => flushed = true);
    await Future<void>.delayed(Duration.zero);
    expect(flushed, false);
    expect(controller.catalog.books.single.lastPosition, anchor);
    expect(controller.catalog.books.single.progress, .3);
    expect(preferences.settings.narrationVoice, 'cedar');
    preferences.firstWrite.complete();
    await reset;
    await flush;
    expect(flushed, true);
    expect(
      (await preferences.load()).toJson(),
      const ReaderSettings().toJson(),
    );
    expect((await controller.catalog.store.load()).single.lastPosition, anchor);
    expect(cache.manifests[book.hash]!.cloudBookId, 'cloud-book');
    expect(cache.manifests[book.hash]!.anchor, anchor);
    expect(cache.files, files);
    expect(api.requests.length, requests);
  });

  test(
    'invalid global narration values never enter preference storage',
    () async {
      final store = MemorySettingsStore();
      final controller = await _controller(settingsStore: store);
      await expectLater(
        controller.preferences.configure(narrationVoice: 'unknown'),
        throwsArgumentError,
      );
      await expectLater(
        controller.preferences.configure(narrationSpeed: double.nan),
        throwsArgumentError,
      );
      expect(store.settings.toJson(), const ReaderSettings().toJson());
    },
  );

  test('usage is not requested while signed out or unconfigured', () async {
    final api = FakeAccountApi();
    final identity = FakeCloudIdentity();
    final controller = await _controller(api: api, identity: identity);
    await controller.refreshAccountUsage();
    expect(api.requests, 0);
    identity.email = 'reader@example.test';
    await controller.refreshCloudAccount();
    api.configured = false;
    await controller.refreshAccountUsage();
    expect(api.requests, 0);
    expect(identity.signIns, 0);
  });

  test(
    'disposal rejects pending usage and prevents further requests',
    () async {
      final pending = Completer<AccountUsage>();
      final api = FakeAccountApi()..response = () => pending.future;
      final identity = FakeCloudIdentity()..email = 'reader@example.test';
      final controller = await _controller(
        api: api,
        identity: identity,
        disposeOnTeardown: false,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);
      final refresh = controller.refreshAccountUsage();
      final beforeDispose = notifications;
      controller.dispose();
      pending.complete(testAccountUsage());
      await refresh;
      expect(controller.accountUsage, isNull);
      expect(notifications, beforeDispose);
      await controller.refreshAccountUsage();
      expect(api.requests, 1);
    },
  );

  test(
    'sign-out fences a pending usage response and prevents duplicate refreshes',
    () async {
      final pending = Completer<AccountUsage>();
      final api = FakeAccountApi()..response = () => pending.future;
      final identity = FakeCloudIdentity()..email = 'reader@example.test';
      final controller = await _controller(api: api, identity: identity);
      final refresh = controller.refreshAccountUsage();
      await controller.refreshAccountUsage();
      expect(api.requests, 1);
      await controller.signOutOfCloud();
      pending.complete(testAccountUsage());
      await refresh;
      expect(controller.accountUsage, isNull);
      expect(controller.usageLoading, false);
    },
  );

  test(
    'account switch discards the preceding account usage response',
    () async {
      final pending = Completer<AccountUsage>();
      final api = FakeAccountApi()..response = () => pending.future;
      final identity = FakeCloudIdentity()..email = 'first@example.test';
      final controller = await _controller(api: api, identity: identity);
      final refresh = controller.refreshAccountUsage();
      identity.email = 'second@example.test';
      await controller.refreshCloudAccount();
      pending.complete(testAccountUsage());
      await refresh;
      expect(controller.cloudEmail, 'second@example.test');
      expect(controller.accountUsage, isNull);
    },
  );

  test(
    'failed refresh removes old balances and preserves a categorized failure',
    () async {
      final api = FakeAccountApi();
      final identity = FakeCloudIdentity()..email = 'reader@example.test';
      final controller = await _controller(api: api, identity: identity);
      await controller.refreshAccountUsage();
      expect(controller.accountUsage!.narrationRemaining, 123456);
      api.response = () => Future.error(
        const AccountUsageException(
          AccountUsageFailureKind.offline,
          'Connect to the internet.',
        ),
      );
      await controller.refreshAccountUsage();
      expect(controller.accountUsage, isNull);
      expect(controller.usageFailure, AccountUsageFailureKind.offline);
      expect(controller.cloudEmail, 'reader@example.test');
    },
  );

  test(
    'unconfigured account deletion preserves Firebase identity and local books',
    () async {
      final identity = FakeCloudIdentity()..email = 'reader@example.test';
      final controller = await _controller(identity: identity);
      await expectLater(
        controller.deleteCloudAccount(),
        throwsA(isA<Exception>()),
      );
      expect(identity.deletions, 0);
      expect(controller.catalog.books, hasLength(1));
      expect(controller.cloudAccountBusy, false);
    },
  );

  test('local cleanup failure reflects deleted identity and retains the complete anchor', () async {
    final identity = FakeCloudIdentity()..email = 'reader@example.test';
    final client = MockClient((request) async {
      expect(request.method, 'DELETE');
      expect(request.url.path, '/v1/account');
      return http.Response('', 204);
    });
    final baseUri = Uri.parse('https://example.test');
    final controller = await _controller(
      identity: identity,
      api: HttpAccountApi(identity: identity, baseUri: baseUri, client: client),
      narrationApi: HttpNarrationApi(
        identity: identity,
        baseUri: baseUri,
        client: client,
      ),
      narrationPlayer: FakeNarrationPlayer(),
      narrationStore: _FailingClearStore(),
      narrationDocuments: MemoryDocumentStore(),
    );
    const anchor = TextPosition(
      version: 1,
      sectionId: 's0',
      blockId: 'p1',
      offset: 2,
    );
    await controller.savePosition(controller.catalog.books.single, anchor, .3);
    await expectLater(
      controller.deleteCloudAccount(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Local audio cleanup failed.',
        ),
      ),
    );
    expect(identity.deletions, 1);
    expect(identity.email, isNull);
    expect(controller.cloudEmail, identity.email);
    expect(controller.cloudAccountBusy, false);
    expect(controller.catalog.books.single.lastPosition, anchor);
    expect(controller.catalog.books.single.progress, .3);
  });
}
