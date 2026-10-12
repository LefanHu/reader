import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/book_analysis/analysis_entity.dart';
import 'package:reader/book_analysis/analysis_result.dart';
import 'package:reader/book_analysis/book_analysis_state.dart';
import 'package:reader/book_analysis/file_analysis_store.dart';
import 'package:reader/book_analysis/services.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/illustrations/file_illustration_store.dart';
import 'package:reader/illustrations/illustration_manifest.dart';
import 'package:reader/illustrations/illustration_profile.dart';
import 'package:reader/importing/import_candidate.dart';
import 'package:reader/library/library_screen.dart';
import 'package:reader/text/document_store.dart';
import 'package:reader/text/text_position.dart';
import 'package:reader/text/viewport.dart';

import '../../test/support/cloud_identity_fake.dart';
import '../../test/support/fake_book_analysis_api.dart';
import 'native_illustration_api.dart';
import 'native_test_app.dart';

const _sections = [
  'Mara arrives with a long braid. Northwatch patrol wears blue uniforms. '
      'The named blade Emberblade rests beside e\u0301 and 👩🏽‍🚀.',
  'Mara cuts her braid. Northwatch patrol changes to red uniforms. '
      'The valley has always been beneath a dark sky. A spell returns daylight. '
      'Emberblade reveals its true appearance; e\u0301 greets 👩🏽‍🚀 again.',
];
const _surfaces = {
  'Mara': EntityKind.individual,
  'Northwatch': EntityKind.group,
  'Emberblade': EntityKind.item_artifact,
  'e\u0301': EntityKind.individual,
  '👩🏽‍🚀': EntityKind.individual,
};

/// Exercises catalog acceptance, startup reconciliation, normalized evidence and
/// atomic sidecars without opening either eligible book or invoking authentication.
Future<void> runDefaultPreprocessingScenario(WidgetTester tester) async {
  final identity = FakeCloudIdentity()..email = 'existing@example.test';
  final api = FakeBookAnalysisApi(surfaces: _surfaces);
  final imageApi = NativeIllustrationApi();
  BookAnalysisServices services(Directory root) => (
    api: api,
    store: FileAnalysisStore(root),
    documents: TextDocumentStore(),
  );
  final bytes = Uint8List.fromList(utf8.encode(_sections.join('\f')));
  final app = await NativeTestApp.launch(
    tester,
    importBooks: false,
    textBytes: bytes,
    cloudIdentity: identity,
    illustrationApi: imageApi,
    analysisServicesFactory: services,
  );
  await app.runWithFrames(() async {
    await app.controller.catalog.pickAndImport();
  });
  final direct = app.book('Unicode Test');
  await _wait(
    tester,
    () =>
        app.controller.analysis!.states[direct.hash]?.status ==
        BookAnalysisStatus.waitingConsent,
    'unconfirmed book to wait for consent',
  );
  expect(api.uploads, isEmpty);
  expect(find.byType(LibraryScreen), findsOneWidget);
  expect(find.byType(TextViewport), findsNothing);

  await app.runWithFrames(() async {
    await _confirmExistingConsent(app, direct, api);
    await app.controller.illustrations.loadManifests(
      app.controller.catalog.books,
    );
    app.controller.analysis!.nudge();
  });
  await _wait(
    tester,
    () => app.controller.analysis!.isComplete(direct),
    'direct TXT import to finish both sections in the library',
  );
  final directMentions = await _durableMentions(app, direct);
  final directState = app.controller.analysis!.states[direct.hash]!;
  expect(directState.processedChunks, directState.requiredChunks);
  expect(
    directState.processedUnits,
    _sections.fold<int>(0, (n, text) => n + text.length),
  );
  expect(directState.requiredUnits, directState.processedUnits);
  expect(app.book('Unicode Test').lastPosition, isNull);
  expect(app.book('Unicode Test').lastOpenedAt, isNull);
  expect(api.manifests.single.sectionCount, 2);
  expect(
    api.uploads
        .expand((chunk) => chunk.primary)
        .map((span) => span.sectionId)
        .toSet(),
    {'s0', 's1'},
  );

  // Model the crash gap after a catalog commit but before its acceptance callback.
  // No analysis queue call occurs for this book: the fresh controller must find it.
  late CatalogBook restored;
  late TextPosition committed;
  await app.runWithFrames(() async {
    await app.controller.flush();
    final startupBytes = Uint8List.fromList(
      utf8.encode('${_sections.join('\f')}\n\nFin.'),
    );
    final imported = await app.controller.catalog.importer.import(
      ImportCandidate(
        name: 'Startup Analysis.txt',
        size: startupBytes.length,
        readBytes: () async => startupBytes,
      ),
      app.controller.catalog.books.map((book) => book.hash).toSet(),
    );
    expect(imported.book, isNotNull);
    final source = imported.book!;
    final section = await TextDocumentStore().loadSection(source.path, 's1');
    committed = TextPosition(
      sectionId: section.id,
      blockId: section.blocks.first.id,
      offset: 5,
    );
    restored = source.copyWith(lastPosition: committed, progress: .5);
    await _confirmExistingConsent(app, restored, api);
    app.controller.catalog.books = [...app.controller.catalog.books, restored];
    await app.store.save(app.controller.catalog.books);
  });
  expect(app.controller.analysis!.states.containsKey(restored.hash), isFalse);
  final uploadsBeforeRestart = api.uploads.length;
  await app.restart();
  await _wait(
    tester,
    () => app.controller.analysis!.isComplete(restored),
    'startup-restored TXT to finish without opening',
  );
  expect(api.uploads.length, greaterThan(uploadsBeforeRestart));
  final startupMentions = await _durableMentions(
    app,
    app.book('Startup Analysis'),
  );
  expect(app.book('Startup Analysis').lastPosition, committed);
  expect(app.book('Startup Analysis').progress, .5);
  expect(app.book('Startup Analysis').lastOpenedAt, isNull);
  expect(find.byType(LibraryScreen), findsOneWidget);
  expect(find.byType(TextViewport), findsNothing);
  expect(await _durableMentions(app, app.book('Unicode Test')), directMentions);

  final completedUploads = api.uploads.length;
  await app.restart();
  expect(
    await _durableMentions(app, app.book('Startup Analysis')),
    startupMentions,
  );
  expect(await _durableMentions(app, app.book('Unicode Test')), directMentions);
  expect(app.book('Startup Analysis').lastPosition, committed);
  expect(
    api.uploads.length,
    completedUploads,
    reason: 'completed source is not re-uploaded',
  );
  expect(imageApi.admissions, isEmpty);
  expect(imageApi.confirmations, isEmpty);
  expect(identity.signIns, 0);
  expect(identity.reauthentications, 0);
  expect(find.text('Illustrate this book?'), findsNothing);

  // A separate unauthenticated shelf still imports and opens locally. Existing
  // consent avoids conflating its account wait with a missing-consent wait.
  await tester.pumpWidget(const SizedBox.shrink());
  await app.runWithFrames(app.controller.flush);
  final signedOutIdentity = FakeCloudIdentity();
  final signedOutApi = FakeBookAnalysisApi(surfaces: _surfaces)
    ..signedOut = true;
  final offlineApp = await NativeTestApp.launch(
    tester,
    importBooks: false,
    textBytes: bytes,
    cloudIdentity: signedOutIdentity,
    analysisServicesFactory: (root) => (
      api: signedOutApi,
      store: FileAnalysisStore(root),
      documents: TextDocumentStore(),
    ),
  );
  await offlineApp.runWithFrames(() async {
    await offlineApp.controller.catalog.pickAndImport();
    final book = offlineApp.book('Unicode Test');
    await _confirmExistingConsent(offlineApp, book, signedOutApi);
    await offlineApp.controller.illustrations.loadManifests(
      offlineApp.controller.catalog.books,
    );
    offlineApp.controller.analysis!.nudge();
  });
  final offlineBook = offlineApp.book('Unicode Test');
  await _wait(
    tester,
    () =>
        offlineApp.controller.analysis!.states[offlineBook.hash]?.status ==
        BookAnalysisStatus.waitingAccount,
    'unauthenticated analysis to wait silently',
  );
  await offlineApp.openBook('Unicode Test');
  expect(find.byType(TextViewport), findsOneWidget);
  expect(offlineApp.viewport.navigation.leadingPosition, isNotNull);
  expect(signedOutApi.uploads, isEmpty);
  expect(signedOutApi.registrations, isEmpty);
  expect(signedOutIdentity.signIns, 0);
  expect(signedOutIdentity.reauthentications, 0);
  expect(
    offlineApp.controller.analysis!.states[offlineBook.hash]!.status,
    BookAnalysisStatus.waitingAccount,
  );
  expect(find.text('Illustrate this book?'), findsNothing);
  expect(tester.takeException(), isNull);
}

Future<void> _confirmExistingConsent(
  NativeTestApp app,
  CatalogBook book,
  FakeBookAnalysisApi api,
) => FileIllustrationStore(app.root).saveManifest(
  book,
  IllustrationManifest(
    bookHash: book.hash,
    profile: IllustrationProfile(
      enabled: false,
      style: 'storybook',
      density: 3,
      providerId: 'openai',
      revision: 1,
      cloudBookId: api.bookIdFor(book),
    ),
  ),
);

Future<List<Map<String, dynamic>>> _durableMentions(
  NativeTestApp app,
  CatalogBook book,
) async {
  late List<Map<String, dynamic>> observed;
  await app.runWithFrames(() async {
    await app.controller.analysis!.flush();
    final store = FileAnalysisStore(app.root);
    final state = (await store.loadState(book))!;
    expect(state.status, BookAnalysisStatus.complete);
    expect(state.finalized!.documentDigest, state.documentDigest);
    final result = <AnalysisMention>[];
    final entities = <AnalysisEntity>[];
    for (final descriptor in state.finalized!.pages) {
      final page = (await store.loadPage(
        book,
        state.finalized!.generationId,
        descriptor.pageId,
      ))!;
      final bytes = utf8.encode(page.serializedJson);
      expect(bytes.length, descriptor.byteLength);
      expect(sha256.convert(bytes).toString(), descriptor.checksum);
      if (page.kind == AnalysisResultPageKind.mentions)
        result.addAll(page.mentions!);
      if (page.kind == AnalysisResultPageKind.entities)
        entities.addAll(page.entities!);
    }
    expect({
      for (final entity in entities) entity.names.single.text: entity.kind,
    }, _surfaces);
    expect(result.length, 10);
    final documents = TextDocumentStore();
    final document = await documents.load(book.path);
    expect(document.sections.length, 2);
    final expected = <String, Map<String, dynamic>>{};
    for (var ordinal = 0; ordinal < 2; ordinal++) {
      final section = await documents.loadSection(
        book.path,
        document.sections[ordinal].id,
      );
      expect(section.blocks.first.text, _sections[ordinal]);
      for (final surface in _surfaces.keys) {
        final offset = _sections[ordinal].indexOf(surface);
        expected['${section.id}/$surface'] = {
          'start': TextPosition(
            version: document.version,
            sectionId: section.id,
            blockId: section.blocks.first.id,
            offset: offset,
          ).toJson(),
          'end': TextPosition(
            version: document.version,
            sectionId: section.id,
            blockId: section.blocks.first.id,
            offset: offset + surface.length,
          ).toJson(),
        };
      }
    }
    expect({
      for (final mention in result)
        '${mention.span.start.sectionId}/${mention.surface}': mention.span
            .toJson(),
    }, expected);
    expect(result.map((mention) => mention.id).toSet().length, result.length);
    observed = result.map((mention) => mention.toJson()).toList();
  });
  return observed;
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() done,
  String description,
) async {
  for (var frame = 0; frame < 1200; frame++) {
    if (done()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail('Timed out waiting for $description.');
}
