import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:reader/account/account_usage.dart';
import 'package:reader/account/account_usage_exception.dart';
import 'package:reader/account/api.dart';
import 'package:reader/account/http_account_api.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/app/reader_controller.dart';
import 'package:reader/identity/cloud_identity.dart';
import 'package:reader/illustrations/http_illustration_api.dart';
import 'package:reader/illustrations/illustration_manifest.dart';
import 'package:reader/illustrations/illustration_profile.dart';
import 'package:reader/app/reader_app.dart';
import 'package:reader/narration/api.dart';
import 'package:reader/narration/http_narration_api.dart';
import 'package:reader/narration/narration_manifest.dart';
import 'package:reader/preferences/library_filter.dart';
import 'package:reader/preferences/library_sort.dart';
import 'package:reader/preferences/reading_theme.dart';
import 'package:reader/settings/settings_navigation.dart';
import 'package:reader/settings/settings_screen.dart';
import 'package:reader/text/text_position.dart';
import 'package:reader/theme.dart';

import 'fixtures/catalog_book.dart';
import 'support/controller_lifecycle.dart';
import 'support/dev_api_books.dart';
import 'support/dev_api_client.dart';
import 'support/dev_api_environment.dart';
import 'support/dev_api_identity.dart';
import 'support/dev_api_pump.dart';
import 'support/memory_illustration_store.dart';
import 'support/test_controller.dart';
import 'fixtures/narration_audio.dart';
import 'support/fake_narration_api.dart';
import 'support/memory_narration_store.dart';
import 'support/fonts.dart';

Future<ReaderController> _mount(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.iOS,
  double width = 390,
  double scale = 1,
  TextDirection direction = TextDirection.ltr,
  ReadingTheme theme = ReadingTheme.paper,
  ReaderController? suppliedController,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = suppliedController ?? await testController();
  await controller.preferences.configure(theme: theme);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await disposeControllerWithFrames(tester, controller);
  });
  await tester.pumpWidget(
    ListenableBuilder(
      listenable: controller,
      builder: (context, _) => MaterialApp(
        theme: buildReaderTheme(controller.preferences.settings.theme)
            .copyWith(platform: platform),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 900),
            textScaler: TextScaler.linear(scale),
          ),
          child: Directionality(
            textDirection: direction,
            child: RepaintBoundary(
              key: const ValueKey('settings-golden'),
              child: SettingsScreen(controller: controller),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _section(
  WidgetTester tester,
  String label, {
  bool settle = true,
}) async {
  final tiles = find.widgetWithText(ListTile, label);
  if (tiles.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      tiles,
      160,
      scrollable: find.byType(Scrollable).first,
    );
  }
  final tile = tiles.first;
  await tester.ensureVisible(tile);
  await tester.tap(tile);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }
}

/// Uses the production singleton route so edge exits also prove completion cleanup.
Future<GlobalKey<NavigatorState>> _mountRouted(
  WidgetTester tester, {
  required bool wide,
}) async {
  await tester.binding.setSurfaceSize(Size(wide ? 1100 : 390, 600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = await testController();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await disposeControllerWithFrames(tester, controller);
  });
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: ThemeData(
        platform: wide ? TargetPlatform.macOS : TargetPlatform.iOS,
      ),
      home: const Scaffold(body: Text('Library sentinel')),
    ),
  );
  unawaited(SettingsNavigation.open(navigator.currentState!, controller));
  await tester.pumpAndSettle();
  return navigator;
}

Future<void> _edgeBack(WidgetTester tester, {bool cancel = false}) async {
  final gesture = await tester.startGesture(const Offset(1, 300));
  var ended = false;
  try {
    await gesture.moveBy(const Offset(50, 0));
    await gesture.moveBy(const Offset(50, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SettingsScreen), findsOneWidget);
    if (cancel) {
      await gesture.cancel();
    } else {
      await gesture.up();
    }
    ended = true;
    await tester.pumpAndSettle();
  } finally {
    if (!ended) await gesture.cancel();
  }
}

Future<ReaderController> _accountController({
  required CloudIdentity identity,
  AccountApi? accountApi,
  NarrationApi? narrationApi,
  MemoryNarrationStore? narrationStore,
  MemoryIllustrationStore? illustrationStore,
  CatalogBook? book,
}) async {
  final controller = await testController(
    books: [book ?? testBook()],
    cloudIdentity: identity,
    accountApi: accountApi,
    illustrationStore: illustrationStore,
    narrationApi: narrationApi ?? FakeNarrationApi(),
    narrationStore: narrationStore,
  );
  await controller.refreshCloudAccount();
  return controller;
}

/// Matches the read-only usage request that Settings refreshes.
bool _isUsage(http.BaseRequest request) =>
    request.method == 'GET' && request.url.path == '/v1/account/usage';

/// Matches the server purge sent by cloud account deletion.
bool _isAccountDeletion(http.BaseRequest request) =>
    request.method == 'DELETE' && request.url.path == '/v1/account';

/// Logged usage statuses; null marks an injected network loss.
List<int?> _usageStatuses(DevApiClient client) => [
  for (final exchange in client.exchanges)
    if (exchange.path == '/v1/account/usage') exchange.status,
];

/// Real-network shared identity, created outside the widget test's fake clock.
Future<DevApiIdentity> _sharedIdentity(WidgetTester tester) async =>
    (await tester.runAsync(DevApiIdentity.shared))!;

/// Narration balance line exactly as Settings renders [usage].
String _narrationBalance(AccountUsage usage) =>
    '${usage.narrationRemaining} of ${usage.narrationMonthlyLimit}\n'
    'Resets ${usage.narrationResetAt.toUtc().toIso8601String().split('T').first} UTC';

/// Becomes true once [hold] has intercepted its request.
bool Function() _heldOnce(DevApiHold hold) {
  var started = false;
  unawaited(hold.started.then((_) => started = true));
  return () => started;
}

void main() {
  setUpAll(loadReaderFonts);

  testWidgets(
    'signed-in usage loads once and refresh replaces real nullable balances',
    (tester) async {
      final client = DevApiClient.create();
      final identity = (await tester.runAsync(DevApiIdentity.disposable))!;
      final baseUri = DevApiEnvironment.instance.baseUri;
      final api = HttpAccountApi(
        identity: identity,
        client: client,
        baseUri: baseUri,
      );
      final narrationApi = HttpNarrationApi(
        identity: identity,
        client: client,
        baseUri: baseUri,
      );
      final store = MemoryNarrationStore();
      final controller = await _accountController(
        identity: identity,
        accountApi: api,
        narrationApi: narrationApi,
        narrationStore: store,
      );
      final firstHold = client.hold(_isUsage);
      final firstLoad = _heldOnce(firstHold);
      await _mount(tester, suppliedController: controller);
      await _section(tester, 'Usage & allowance', settle: false);
      await pumpUntilDev(tester, firstLoad);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Narration characters remaining'), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Refresh allowance'),
            )
            .onPressed,
        isNull,
      );
      firstHold.release();
      await pumpUntilDev(tester, () => controller.accountUsage != null);
      await tester.pumpAndSettle();
      final usage = (await tester.runAsync(api.usage))!;
      expect(find.text(_narrationBalance(usage)), findsOneWidget);
      expect(find.text('Not activated'), findsOneWidget);

      await tester.runAsync(
        () => HttpIllustrationApi(
          identity: identity,
          client: client,
          baseUri: baseUri,
        ).registerBook(devBook(), chapterCount: 1),
      );
      final refresh = client.hold(_isUsage);
      final refreshHeld = _heldOnce(refresh);
      await tester.tap(find.text('Refresh allowance'));
      await tester.pump();
      await pumpUntilDev(tester, refreshHeld);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text(_narrationBalance(usage)), findsNothing);
      expect(find.text('Not activated'), findsNothing);
      refresh.release();
      await pumpUntilDev(tester, () => controller.accountUsage != null);
      await tester.pumpAndSettle();
      expect(find.text('100 remaining · 0 reserved'), findsOneWidget);
      expect(find.text(_narrationBalance(usage)), findsOneWidget);
      expect(_usageStatuses(client), [200, 200, 200]);
      expect(identity.signIns, 0);
      expect(
        client.exchanges.where(
          (exchange) => exchange.path == '/v1/narration/books',
        ),
        isEmpty,
      );
      expect(
        (await store.load(controller.catalog.books.single)).cloudBookId,
        isNull,
      );
    },
    timeout: devApiTimeout,
  );

  for (final (kind, heading, message) in [
    (
      AccountUsageFailureKind.offline,
      'You are offline',
      'Connect to the internet to view account usage.',
    ),
    (
      AccountUsageFailureKind.attestation,
      'App verification required',
      'Account authentication or App Check could not be verified.',
    ),
    (
      AccountUsageFailureKind.service,
      'Usage service unavailable',
      'Account usage is temporarily unavailable.',
    ),
  ]) {
    testWidgets('usage ${kind.name} failure is visible and retryable', (
      tester,
    ) async {
      final client = DevApiClient.create();
      final identity = await _sharedIdentity(tester);
      final baseUri = DevApiEnvironment.instance.baseUri;
      final narrationApi = HttpNarrationApi(
        identity: identity,
        client: client,
        baseUri: baseUri,
      );
      final store = MemoryNarrationStore();
      final controller = await _accountController(
        identity: identity,
        accountApi: HttpAccountApi(
          identity: identity,
          client: client,
          baseUri: baseUri,
        ),
        narrationApi: narrationApi,
        narrationStore: store,
      );
      await _mount(tester, suppliedController: controller);
      await _section(tester, 'Usage & allowance', settle: false);
      await pumpUntilDev(tester, () => controller.accountUsage != null);
      await tester.pumpAndSettle();
      expect(find.text('Narration characters remaining'), findsOneWidget);
      switch (kind) {
        case AccountUsageFailureKind.offline:
          client.failNext(_isUsage);
        case AccountUsageFailureKind.attestation:
          identity.rejectAppCheck = true;
        case AccountUsageFailureKind.service:
          client.missingRoute(_isUsage);
      }
      await tester.tap(find.text('Refresh allowance'));
      await tester.pump();
      expect(find.text('Narration characters remaining'), findsNothing);
      await pumpUntilDev(tester, () => controller.usageError != null);
      await tester.pumpAndSettle();
      expect(find.text(heading), findsOneWidget);
      expect(find.text(message), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Refresh allowance'),
            )
            .onPressed,
        isNotNull,
      );
      identity.rejectAppCheck = false;
      await tester.tap(find.text('Refresh allowance'));
      await tester.pump();
      await pumpUntilDev(tester, () => controller.accountUsage != null);
      await tester.pumpAndSettle();
      expect(find.text(heading), findsNothing);
      expect(
        find.text(_narrationBalance(controller.accountUsage!)),
        findsOneWidget,
      );
      expect(_usageStatuses(client), [
        200,
        switch (kind) {
          AccountUsageFailureKind.offline => null,
          AccountUsageFailureKind.attestation => 401,
          AccountUsageFailureKind.service => 404,
        },
        200,
      ]);
      expect(identity.email, 'dev-api-test-shared@dev-api.test');
      expect(identity.signIns, 0);
      expect(
        client.exchanges.where(
          (exchange) => exchange.path == '/v1/narration/books',
        ),
        isEmpty,
      );
      expect(
        (await store.load(controller.catalog.books.single)).cloudBookId,
        isNull,
      );
    }, timeout: devApiTimeout);
  }

  for (final switchAccount in [false, true]) {
    testWidgets(
      'late usage after ${switchAccount ? 'account switch' : 'sign-out'} cannot restore balances',
      (tester) async {
        final client = DevApiClient.create();
        final identity = await _sharedIdentity(tester);
        final hold = client.hold(_isUsage);
        final held = _heldOnce(hold);
        final controller = await _accountController(
          identity: identity,
          accountApi: HttpAccountApi(
            identity: identity,
            client: client,
            baseUri: DevApiEnvironment.instance.baseUri,
          ),
        );
        await _mount(tester, suppliedController: controller);
        await _section(tester, 'Usage & allowance', settle: false);
        await pumpUntilDev(tester, held);
        if (switchAccount) {
          await tester.runAsync(
            () => identity.switchAccount('dev-api-test-shared-b'),
          );
          await controller.refreshCloudAccount();
        } else {
          await controller.signOutOfCloud();
        }
        await tester.pumpAndSettle();
        hold.release();
        await pumpUntilDev(tester, () => _usageStatuses(client).isNotEmpty);
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('Narration characters remaining'), findsNothing);
        expect(find.text('Illustration credits'), findsNothing);
        expect(controller.accountUsage, isNull);
        expect(_usageStatuses(client), [200]);
        if (switchAccount) {
          expect(controller.cloudEmail, 'dev-api-test-shared-b@dev-api.test');
          await tester.tap(find.text('Refresh allowance'));
          await tester.pump();
          await pumpUntilDev(tester, () => controller.accountUsage != null);
          await tester.pumpAndSettle();
          expect(_usageStatuses(client), [200, 200]);
          expect(find.text('Narration characters remaining'), findsOneWidget);
        } else {
          expect(find.text('Sign in to view your allowance.'), findsOneWidget);
        }
      },
      timeout: devApiTimeout,
    );
  }

  for (final (failure, failureStatus, failureMessage) in [
    ('missing endpoint', 404, 'Cloud service error (404).'),
    ('rejected credentials', 401, 'Authentication and App Check are required.'),
  ]) {
    testWidgets(
      'account deletion $failure ($failureStatus) preserves local state and a later 204 clears cloud registration',
      (tester) async {
        const anchor = TextPosition(
          version: 1,
          sectionId: 's0',
          blockId: 'p1',
          offset: 2,
        );
        final book = testBook(
          position: anchor,
          progress: .3,
        ).copyWith(wordCount: 42);
        final client = DevApiClient.create();
        final identity = (await tester.runAsync(DevApiIdentity.disposable))!;
        final email = identity.email!;
        final store = MemoryNarrationStore();
        final registration = NarrationManifest(
          account: 'account',
          cloudBookId: book.hash,
          anchor: anchor,
          chunkId: 'cached-chunk',
          offsetMs: 700,
        );
        await store.save(book, registration);
        await store.put(book, 'cached-audio', testWav());
        final illustrations = MemoryIllustrationStore();
        final illustrationConsent = IllustrationManifest(
          bookHash: book.hash,
          profile: const IllustrationProfile(
            enabled: true,
            style: 'Ink',
            density: 2,
            providerId: 'openai',
            revision: 1,
            cloudBookId: 'illustration-book',
          ),
        );
        await illustrations.saveManifest(book, illustrationConsent);
        final baseUri = DevApiEnvironment.instance.baseUri;
        final controller = await _accountController(
          identity: identity,
          book: book,
          narrationStore: store,
          illustrationStore: illustrations,
          accountApi: HttpAccountApi(
            identity: identity,
            client: client,
            baseUri: baseUri,
          ),
          narrationApi: HttpNarrationApi(
            identity: identity,
            client: client,
            baseUri: baseUri,
          ),
        );
        await _mount(tester, suppliedController: controller);
        await _section(tester, 'Account');
        final deleteButton = find.widgetWithText(
          OutlinedButton,
          'Delete cloud account',
        );
        await tester.tap(deleteButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(client.exchanges, isEmpty);
        expect(identity.reauthentications, 0);

        if (failureStatus == 404) {
          client.missingRoute(_isAccountDeletion);
        } else {
          identity.rejectAppCheck = true;
        }
        final deletion = client.hold(_isAccountDeletion);
        final held = _heldOnce(deletion);
        await tester.tap(deleteButton);
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(FilledButton, 'Delete cloud account'),
        );
        await tester.pump();
        await pumpUntilDev(tester, held);
        expect(identity.reauthentications, 1);
        expect(controller.cloudAccountBusy, true);
        expect(tester.widget<OutlinedButton>(deleteButton).onPressed, isNull);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Sign out'),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(deleteButton);
        await tester.pumpAndSettle();
        expect(find.text('Delete cloud account?'), findsNothing);
        deletion.release();
        await pumpUntilDev(tester, () => !controller.cloudAccountBusy);
        await tester.pumpAndSettle();
        expect(find.text(failureMessage), findsOneWidget);
        expect(client.exchanges.map((exchange) => '$exchange'), [
          'DELETE /v1/account -> $failureStatus',
        ]);
        expect(find.text(email), findsWidgets);
        expect(identity.deletions, 0);
        expect(identity.email, email);
        expect(controller.cloudAccountBusy, false);
        expect((await store.load(book)).toJson(), registration.toJson());
        expect(await store.cached(book, 'cached-audio'), isNotNull);
        expect((await illustrations.loadManifest(book)).profile?.enabled, true);
        expect(controller.catalog.books.single.toJson(), book.toJson());

        identity.rejectAppCheck = false;
        await tester.tap(deleteButton);
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(FilledButton, 'Delete cloud account'),
        );
        await tester.pump();
        await pumpUntilDev(
          tester,
          () => identity.deletions == 1 && !controller.cloudAccountBusy,
        );
        await tester.pumpAndSettle();
        expect(client.exchanges.map((exchange) => '$exchange'), [
          'DELETE /v1/account -> $failureStatus',
          'DELETE /v1/account -> 204',
        ]);
        expect(find.text('You are signed out'), findsOneWidget);
        expect(find.text('Sign in with Google'), findsOneWidget);
        expect(deleteButton, findsNothing);
        expect(identity.deletions, 1);
        expect(identity.email, isNull);
        expect(controller.cloudEmail, isNull);
        final forgotten = await store.load(book);
        expect(forgotten.cloudBookId, isNull);
        expect(forgotten.account, isNull);
        expect(forgotten.anchor?.toJson(), anchor.toJson());
        expect(forgotten.chunkId, isNull);
        expect(forgotten.offsetMs, 0);
        expect(await store.cached(book, 'cached-audio'), isNull);
        expect((await illustrations.loadManifest(book)).profile, isNull);
        expect(controller.catalog.books.single.toJson(), book.toJson());
        await controller.flush();
        expect(
          controller.catalog.books.single.lastPosition?.toJson(),
          anchor.toJson(),
        );
        expect(controller.catalog.books.single.progress, .3);
      },
      timeout: devApiTimeout,
    );
  }

  testWidgets(
    'compact settings apply global narration, appearance and library preferences',
    (tester) async {
      final controller = await _mount(tester);
      final semantics = tester.ensureSemantics();
      try {
        await _section(tester, 'Narration');
        await tester.tap(find.text('Cedar'));
        await tester.pumpAndSettle();
        expect(
          tester
              .getSemantics(find.widgetWithText(ListTile, 'Cedar'))
              .getSemanticsData()
              .flagsCollection
              .isSelected,
          Tristate.isTrue,
        );
        expect(
          tester
              .getSemantics(find.widgetWithText(ListTile, 'Marin'))
              .getSemanticsData()
              .flagsCollection
              .isSelected,
          Tristate.isFalse,
        );
      } finally {
        semantics.dispose();
      }
      await tester.tap(find.text('1.5×'));
      await tester.pumpAndSettle();
      expect(controller.preferences.settings.narrationVoice, 'cedar');
      expect(controller.preferences.settings.narrationSpeed, 1.5);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await _section(tester, 'Appearance');
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      expect(controller.preferences.settings.theme, ReadingTheme.dark);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await _section(tester, 'Library');
      await tester.tap(find.text('Finished'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Title'));
      await tester.pumpAndSettle();
      expect(
        controller.preferences.settings.libraryFilter,
        LibraryFilter.finished,
      );
      expect(controller.preferences.settings.librarySort, LibrarySort.title);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large RTL settings fit narrow widths and reset only preferences after confirmation',
    (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'Reader',
        packageName: 'reader',
        version: '2.3.4',
        buildNumber: '17',
        buildSignature: '',
      );
      final controller = await _mount(
        tester,
        platform: TargetPlatform.macOS,
        width: 320,
        scale: 2,
        direction: TextDirection.rtl,
      );
      await controller.preferences.configure(
        narrationVoice: 'cedar',
        theme: ReadingTheme.dark,
      );
      await tester.pumpAndSettle();
      await _section(tester, 'About');
      expect(find.text('Version 2.3.4 (17)'), findsOneWidget);
      final reset = find.text('Reset preferences');
      await tester.ensureVisible(reset);
      await tester.tap(reset);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.preferences.settings.narrationVoice, 'cedar');
      await tester.tap(reset);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Reset preferences'));
      await tester.pumpAndSettle();
      expect(controller.preferences.settings.narrationVoice, 'marin');
      expect(controller.preferences.settings.theme, ReadingTheme.paper);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop sidebar keeps usage signed out and clears cache without false errors',
    (tester) async {
      final controller = await _mount(
        tester,
        platform: TargetPlatform.macOS,
        width: 1100,
      );
      expect(find.byType(VerticalDivider), findsOneWidget);
      await _section(tester, 'Usage & allowance');
      expect(find.text('Sign in to view your allowance.'), findsOneWidget);
      expect(controller.accountUsage, isNull);
      await _section(tester, 'Storage & privacy');
      expect(find.text('0.0 MiB'), findsOneWidget);
      await tester.tap(find.text('Clear narration cache'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear narration cache'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Clear cache'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native Settings requests use the same route as the library gear',
    (tester) async {
      final controller = await testController();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await controller.flush();
      });
      await tester.pumpWidget(ReaderApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await _section(tester, 'Narration');
      expect(find.text('Cedar'), findsOneWidget);
      Future<void> nativeRequest() async {
        final response = Completer<void>();
        tester.binding.channelBuffers.push(
          'reader/settings',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('openSettings'),
          ),
          (_) => response.complete(),
        );
        await response.future;
        await tester.pumpAndSettle();
      }

      await nativeRequest();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('Cedar'), findsOneWidget);
      Navigator.of(tester.element(find.byType(SettingsScreen))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      await nativeRequest();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'repeated settings requests share a route and allow reopening after close',
    (tester) async {
      final controller = await testController();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await disposeControllerWithFrames(tester, controller);
      });
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Library')),
        ),
      );
      final first = SettingsNavigation.open(
        navigator.currentState!,
        controller,
      );
      await tester.pumpAndSettle();
      await _section(tester, 'Narration');
      await tester.tap(find.text('Cedar'));
      await tester.pumpAndSettle();
      var firstClosed = false;
      var secondClosed = false;
      unawaited(
        first.then((_) {
          firstClosed = true;
        }),
      );
      final second = SettingsNavigation.open(
        navigator.currentState!,
        controller,
      );
      unawaited(
        second.then((_) {
          secondClosed = true;
        }),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('Cedar'), findsOneWidget);
      expect(controller.preferences.settings.narrationVoice, 'cedar');
      expect(firstClosed, false);
      expect(secondClosed, false);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await first;
      await second;
      expect(firstClosed, true);
      expect(secondClosed, true);
      expect(find.byType(SettingsScreen), findsNothing);
      final reopened = SettingsNavigation.open(
        navigator.currentState!,
        controller,
      );
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      await _section(tester, 'Narration');
      expect(find.text('Cedar'), findsOneWidget);
      expect(controller.preferences.settings.narrationVoice, 'cedar');
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await reopened;
    },
  );

  for (final wide in [false, true]) {
    testWidgets(
      '${wide ? 'wide' : 'compact'} edge Back follows Settings hierarchy',
      (tester) async {
        await _mountRouted(tester, wide: wide);
        await _section(tester, 'Reading');
        await _edgeBack(tester);
        if (!wide) {
          expect(find.widgetWithText(ListTile, 'Reading'), findsOneWidget);
          expect(find.text('Settings'), findsOneWidget);
          await _edgeBack(tester);
        }
        expect(find.text('Library sentinel'), findsOneWidget);
        expect(find.byType(SettingsScreen), findsNothing);
      },
    );

    testWidgets(
      '${wide ? 'wide' : 'compact'} interior and cancelled swipes retain detail',
      (tester) async {
        await _mountRouted(tester, wide: wide);
        await _section(tester, 'Reading');
        final detail = tester.widget<AppBar>(find.byType(AppBar)).title;
        await tester.dragFrom(const Offset(24, 300), const Offset(100, 0));
        await tester.pumpAndSettle();
        await _edgeBack(tester, cancel: true);
        expect(tester.widget<AppBar>(find.byType(AppBar)).title, detail);
        expect(find.byType(SettingsScreen), findsOneWidget);
        if (!wide) {
          expect(find.widgetWithText(ListTile, 'Reading'), findsNothing);
        }
      },
    );

    testWidgets(
      '${wide ? 'wide' : 'compact'} confirmation covers Settings edge Back',
      (tester) async {
        await _mountRouted(tester, wide: wide);
        PackageInfo.setMockInitialValues(
          appName: 'Reader',
          packageName: 'reader',
          version: '1',
          buildNumber: '1',
          buildSignature: '',
        );
        await _section(tester, 'About');
        await tester.ensureVisible(find.text('Reset preferences'));
        await tester.tap(find.text('Reset preferences'));
        await tester.pumpAndSettle();
        await _edgeBack(tester);
        expect(find.text('Reset preferences?'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Reset preferences'), findsOneWidget);
        expect(find.byType(SettingsScreen), findsOneWidget);
        if (!wide) expect(find.widgetWithText(ListTile, 'About'), findsNothing);
      },
    );
  }

  testWidgets(
    'compact system Back unwinds detail before completing Settings route',
    (tester) async {
      final navigator = await _mountRouted(tester, wide: false);
      await _section(tester, 'Reading');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Reading'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Library sentinel'), findsOneWidget);
      // Route completion removes the singleton; opening again must create a route.
      final controller = await testController();
      addTearDown(controller.dispose);
      unawaited(SettingsNavigation.open(navigator.currentState!, controller));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
    },
  );

  testWidgets('edge vertical gesture scrolls compact categories without exit', (
    tester,
  ) async {
    await _mountRouted(tester, wide: false);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    await tester.dragFrom(const Offset(1, 450), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  for (final theme in ReadingTheme.values) {
    for (final desktop in [false, true]) {
      testWidgets(
        'settings ${theme.name} ${desktop ? 'desktop' : 'compact'} appearance golden',
        (tester) async {
          await _mount(
            tester,
            platform: desktop ? TargetPlatform.macOS : TargetPlatform.iOS,
            width: desktop ? 1100 : 390,
            theme: theme,
          );
          await _section(tester, 'Appearance');
          await expectLater(
            find.byKey(const ValueKey('settings-golden')),
            matchesGoldenFile(
              'goldens/settings-${theme.name}-${desktop ? 'desktop' : 'compact'}.png',
            ),
          );
        },
      );
    }
  }
}
