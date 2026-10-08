import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reader/account/api.dart';
import 'package:reader/book_service.dart';
import 'package:reader/controller.dart';
import 'package:reader/models.dart';
import 'package:reader/narration/api.dart';
import 'package:reader/narration/player.dart';
import 'package:reader/narration/session.dart';
import 'package:reader/narration/store.dart';
import 'package:reader/text/document.dart';

import 'fakes.dart';
import 'support/account_fakes.dart';
import 'support/cloud_identity_fake.dart';
import 'support/narration_fakes.dart';

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
  FakeAccountApi? api,
  FakeCloudIdentity? identity,
  MemorySettingsStore? settingsStore,
  NarrationApi? narrationApi,
  NarrationPlayer? narrationPlayer,
  NarrationStore? narrationStore,
  TextDocumentStore? narrationDocuments,
  bool disposeOnTeardown = true,
}) async {
  final controller = ReaderController(
    accountApi: api,
    cloudIdentity: identity,
    narrationApi: narrationApi,
    narrationPlayer: narrationPlayer,
    narrationStore: narrationStore,
    narrationDocuments: narrationDocuments,
    catalogStore: MemoryCatalogStore([testBook()]),
    settingsStore: settingsStore ?? MemorySettingsStore(),
    importer: BookImporter(root: Directory.systemTemp),
    picker: FakePicker(),
    illustrationStore: MemoryIllustrationStore(),
    illustrationApi: FakeIllustrationApi(),
    wordCounter: FakeWordCounter(),
  );
  await controller.initialize();
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
      final first = controller.configure(libraryFilter: LibraryFilter.reading);
      final second = controller.configure(fontSize: 125);
      await Future<void>.delayed(Duration.zero);
      expect(store.writes, 1);
      store.firstWrite.complete();
      await Future.wait([first, second]);
      expect(store.settings.libraryFilter, LibraryFilter.reading);
      expect(store.settings.fontSize, 125);
    },
  );

  test(
    'reset restores global preferences and retains books and identity',
    () async {
      final identity = FakeCloudIdentity()..email = 'reader@example.test';
      final controller = await _controller(identity: identity);
      final position = controller.books.single.lastPosition;
      await controller.configure(
        theme: ReadingTheme.dark,
        narrationVoice: 'cedar',
        narrationSpeed: 1.75,
        librarySort: LibrarySort.title,
      );
      await controller.resetPreferences();
      expect(controller.settings.toJson(), const ReaderSettings().toJson());
      expect(controller.books.single.lastPosition, position);
      expect(controller.cloudEmail, 'reader@example.test');
      expect(identity.signOuts, 0);
    },
  );

  test('reset during playback retains consent and anchors and waits for preference persistence', () async {
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
    await controller.savePosition(controller.books.single, anchor, .3);
    final book = controller.books.single;
    await controller.consentToNarration(book);
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

    final reset = controller.resetPreferences();
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
    expect(controller.books.single.lastPosition, anchor);
    expect(controller.books.single.progress, .3);
    expect(preferences.settings.narrationVoice, 'cedar');
    preferences.firstWrite.complete();
    await reset;
    await flush;
    expect(flushed, true);
    expect(
      (await preferences.load()).toJson(),
      const ReaderSettings().toJson(),
    );
    expect((await controller.catalogStore.load()).single.lastPosition, anchor);
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
        controller.configure(narrationVoice: 'unknown'),
        throwsArgumentError,
      );
      await expectLater(
        controller.configure(narrationSpeed: double.nan),
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
      expect(controller.books, hasLength(1));
      expect(controller.cloudAccountBusy, false);
    },
  );

  test('local cleanup failure reflects deleted identity and retains the complete anchor', () async {
    final identity = FakeCloudIdentity()..email = 'reader@example.test';
    final api = HttpNarrationApi(
      identity: identity,
      baseUri: Uri.parse('https://example.test'),
      client: MockClient((request) async {
        expect(request.method, 'DELETE');
        expect(request.url.path, '/v1/account');
        return http.Response('', 204);
      }),
    );
    final controller = await _controller(
      identity: identity,
      narrationApi: api,
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
    await controller.savePosition(controller.books.single, anchor, .3);
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
    expect(controller.books.single.lastPosition, anchor);
    expect(controller.books.single.progress, .3);
  });
}
