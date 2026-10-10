import 'dart:async';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:reader/account/account_usage.dart';
import 'package:reader/account/account_usage_exception.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/app/reader_controller.dart';
import 'package:reader/illustrations/illustration_manifest.dart';
import 'package:reader/illustrations/illustration_profile.dart';
import 'package:reader/importing/book_importer.dart';
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
import 'support/fake_illustration_api.dart';
import 'support/fake_picker.dart';
import 'support/fake_word_counter.dart';
import 'support/memory_catalog_store.dart';
import 'support/memory_document_store.dart';
import 'support/memory_illustration_store.dart';
import 'support/memory_settings_store.dart';
import 'support/test_controller.dart';
import 'fixtures/account_usage.dart';
import 'support/fake_account_api.dart';
import 'support/cloud_identity_fake.dart';
import 'fixtures/narration_audio.dart';
import 'support/fake_narration_api.dart';
import 'support/fake_narration_player.dart';
import 'support/memory_narration_store.dart';

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
    controller.dispose();
    // Native-fake stream shutdown needs its queued callbacks drained before flush.
    await tester.pumpAndSettle();
    await controller.flush();
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

Future<ReaderController> _accountController({
  required FakeCloudIdentity identity,
  FakeAccountApi? accountApi,
  NarrationApi? narrationApi,
  MemoryNarrationStore? narrationStore,
  MemoryIllustrationStore? illustrationStore,
  CatalogBook? book,
}) async {
  final controller = ReaderController(
    cloudIdentity: identity,
    accountApi: accountApi,
    catalogStore: MemoryCatalogStore([book ?? testBook()]),
    settingsStore: MemorySettingsStore(),
    importer: BookImporter(root: Directory.systemTemp),
    picker: FakePicker(),
    wordCounter: FakeWordCounter(),
    illustrationApi: FakeIllustrationApi(),
    illustrationStore: illustrationStore ?? MemoryIllustrationStore(),
    narrationApi: narrationApi ?? FakeNarrationApi(),
    narrationPlayer: FakeNarrationPlayer(),
    narrationStore: narrationStore ?? MemoryNarrationStore(),
    narrationDocuments: MemoryDocumentStore(),
  );
  await controller.initialize();
  await controller.refreshCloudAccount();
  return controller;
}

void main() {
  setUpAll(() async {
    for (final (family, path) in [
      ('Lora', 'assets/fonts/Lora.ttf'),
      ('DM Sans', 'assets/fonts/DMSans.ttf'),
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(path))).load();
    }
  });

  testWidgets(
    'signed-in usage loads once and refresh replaces real nullable balances',
    (tester) async {
      final identity = FakeCloudIdentity()..email = 'reader@example.test';
      final pending = Completer<AccountUsage>();
      final api = FakeAccountApi()..response = () => pending.future;
      final narrationApi = FakeNarrationApi();
      final store = MemoryNarrationStore();
      final controller = await _accountController(
        identity: identity,
        accountApi: api,
        narrationApi: narrationApi,
        narrationStore: store,
      );
      await _mount(tester, suppliedController: controller);
      await _section(tester, 'Usage & allowance', settle: false);
      expect(api.requests, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('123456 of 500000'), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Refresh allowance'),
            )
            .onPressed,
        isNull,
      );
      pending.complete(testAccountUsage());
      await tester.pumpAndSettle();
      expect(
        find.text('123456 of 500000\nResets 2026-11-01 UTC'),
        findsOneWidget,
      );
      expect(find.text('Not activated'), findsOneWidget);

      final refresh = Completer<AccountUsage>();
      api.response = () => refresh.future;
      await tester.tap(find.text('Refresh allowance'));
      await tester.pump();
      expect(api.requests, 2);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('123456 of 500000'), findsNothing);
      expect(find.text('Not activated'), findsNothing);
      refresh.complete(
        testAccountUsage(
          illustrationCreditsRemaining: 20,
          illustrationCreditsReserved: 3,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('20 remaining · 3 reserved'), findsOneWidget);
      expect(find.textContaining('123456 of 500000'), findsOneWidget);
      expect(identity.signIns, 0);
      expect(narrationApi.registrations, 0);
      expect(narrationApi.requests, isEmpty);
      expect(
        (await store.load(controller.catalog.books.single)).cloudBookId,
        isNull,
      );
    },
  );

  for (final (kind, heading) in [
    (AccountUsageFailureKind.offline, 'You are offline'),
    (AccountUsageFailureKind.attestation, 'App verification required'),
    (AccountUsageFailureKind.service, 'Usage service unavailable'),
  ]) {
    testWidgets('usage ${kind.name} failure is visible and retryable', (
      tester,
    ) async {
      final identity = FakeCloudIdentity()..email = 'reader@example.test';
      final api = FakeAccountApi();
      final narrationApi = FakeNarrationApi();
      final store = MemoryNarrationStore();
      final controller = await _accountController(
        identity: identity,
        accountApi: api,
        narrationApi: narrationApi,
        narrationStore: store,
      );
      await _mount(tester, suppliedController: controller);
      await _section(tester, 'Usage & allowance');
      expect(find.textContaining('123456 of 500000'), findsOneWidget);
      final pending = Completer<AccountUsage>();
      api.response = () => pending.future;
      await tester.tap(find.text('Refresh allowance'));
      await tester.pump();
      expect(find.textContaining('123456 of 500000'), findsNothing);
      pending.completeError(AccountUsageException(kind, 'Please try again.'));
      await tester.pumpAndSettle();
      expect(find.text(heading), findsOneWidget);
      expect(find.text('Please try again.'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Refresh allowance'),
            )
            .onPressed,
        isNotNull,
      );
      api.response = () async => testAccountUsage();
      await tester.tap(find.text('Refresh allowance'));
      await tester.pumpAndSettle();
      expect(find.text(heading), findsNothing);
      expect(find.textContaining('123456 of 500000'), findsOneWidget);
      expect(api.requests, 3);
      expect(identity.email, 'reader@example.test');
      expect(identity.signIns, 0);
      expect(narrationApi.registrations, 0);
      expect(narrationApi.requests, isEmpty);
      expect(
        (await store.load(controller.catalog.books.single)).cloudBookId,
        isNull,
      );
    });
  }

  for (final switchAccount in [false, true]) {
    testWidgets(
      'late usage after ${switchAccount ? 'account switch' : 'sign-out'} cannot restore balances',
      (tester) async {
        final identity = FakeCloudIdentity()..email = 'reader@example.test';
        final pending = Completer<AccountUsage>();
        final api = FakeAccountApi()..response = () => pending.future;
        final controller = await _accountController(
          identity: identity,
          accountApi: api,
        );
        await _mount(tester, suppliedController: controller);
        await _section(tester, 'Usage & allowance', settle: false);
        if (switchAccount) {
          identity.email = 'other@example.test';
          await controller.refreshCloudAccount();
        } else {
          await controller.signOutOfCloud();
        }
        await tester.pumpAndSettle();
        pending.complete(
          testAccountUsage(
            illustrationCreditsRemaining: 20,
            illustrationCreditsReserved: 3,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.textContaining('123456 of 500000'), findsNothing);
        expect(find.text('20 remaining · 3 reserved'), findsNothing);
        expect(controller.accountUsage, isNull);
        expect(api.requests, 1);
        if (switchAccount) {
          expect(controller.cloudEmail, 'other@example.test');
          api.response = () async => testAccountUsage();
          await tester.tap(find.text('Refresh allowance'));
          await tester.pumpAndSettle();
          expect(api.requests, 2);
          expect(find.text('Not activated'), findsOneWidget);
        } else {
          expect(find.text('Sign in to view your allowance.'), findsOneWidget);
        }
      },
    );
  }

  for (final failureStatus in [404, 503]) {
    testWidgets(
      'account deletion $failureStatus preserves local state and a later 204 clears cloud consent',
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
        final identity = FakeCloudIdentity()..email = 'reader@example.test';
        final store = MemoryNarrationStore();
        final consent = NarrationManifest(
          account: 'account',
          cloudBookId: book.hash,
          anchor: anchor,
          chunkId: 'cached-chunk',
          offsetMs: 700,
        );
        await store.save(book, consent);
        await store.put(book, 'cached-audio', testWav());
        final illustrations = MemoryIllustrationStore();
        final illustrationConsent = IllustrationManifest(
          bookHash: book.hash,
          profile: const IllustrationProfile(
            enabled: true,
            style: 'Ink',
            density: 2,
            styleVersion: 1,
            cloudBookId: 'illustration-book',
          ),
        );
        await illustrations.saveManifest(book, illustrationConsent);
        final requests = <http.Request>[];
        var deletion = Completer<http.Response>();
        final client = MockClient((request) {
          requests.add(request);
          return deletion.future;
        });
        addTearDown(client.close);
        final controller = await _accountController(
          identity: identity,
          book: book,
          narrationStore: store,
          illustrationStore: illustrations,
          narrationApi: HttpNarrationApi(
            identity: identity,
            client: client,
            baseUri: Uri.parse('https://example.test'),
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
        expect(requests, isEmpty);
        expect(identity.reauthentications, 0);

        await tester.tap(deleteButton);
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(FilledButton, 'Delete cloud account'),
        );
        await tester.pumpAndSettle();
        expect(requests, hasLength(1));
        expect(requests.single.method, 'DELETE');
        expect(requests.single.url.path, '/v1/account');
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
        await tester.pump();
        expect(requests, hasLength(1));
        deletion.complete(http.Response('', failureStatus));
        await tester.pumpAndSettle();
        expect(
          find.text('Bad state: Narration service error ($failureStatus).'),
          findsOneWidget,
        );
        expect(find.text('reader@example.test'), findsWidgets);
        expect(identity.deletions, 0);
        expect(identity.email, 'reader@example.test');
        expect(controller.cloudAccountBusy, false);
        expect((await store.load(book)).toJson(), consent.toJson());
        expect(await store.cached(book, 'cached-audio'), isNotNull);
        expect((await illustrations.loadManifest(book)).profile?.enabled, true);
        expect(controller.catalog.books.single.toJson(), book.toJson());

        deletion = Completer<http.Response>();
        await tester.tap(deleteButton);
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(FilledButton, 'Delete cloud account'),
        );
        await tester.pumpAndSettle();
        expect(requests, hasLength(2));
        deletion.complete(http.Response('', 204));
        await tester.pumpAndSettle();
        expect(find.text('You are signed out'), findsOneWidget);
        expect(find.text('Sign in with Google'), findsOneWidget);
        expect(deleteButton, findsNothing);
        expect(identity.deletions, 1);
        expect(identity.email, isNull);
        expect(controller.cloudEmail, isNull);
        expect((await store.load(book)).cloudBookId, isNull);
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
        controller.dispose();
        await controller.flush();
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
