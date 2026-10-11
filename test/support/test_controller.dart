import 'dart:io';

import 'package:reader/account/api.dart';
import 'package:reader/app/reader_controller.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/catalog/catalog_store.dart';
import 'package:reader/cloud_deletion_outbox.dart';
import 'package:reader/identity/cloud_identity.dart';
import 'package:reader/illustrations/api.dart';
import 'package:reader/illustrations/indexer.dart';
import 'package:reader/illustrations/store.dart';
import 'package:reader/importing/book_importer.dart';
import 'package:reader/importing/import_candidate.dart';
import 'package:reader/narration/api.dart';
import 'package:reader/narration/cloud_narration_source.dart';
import 'package:reader/narration/player.dart';
import 'package:reader/narration/source.dart';
import 'package:reader/narration/store.dart';
import 'package:reader/preferences/settings_store.dart';
import 'package:reader/text/book_word_counter.dart';
import 'package:reader/text/document_store.dart';

import 'cloud_identity_fake.dart';
import 'fake_illustration_api.dart';
import 'fake_narration_api.dart';
import 'fake_narration_player.dart';
import 'fake_picker.dart';
import 'fake_text_indexer.dart';
import 'fake_word_counter.dart';
import 'memory_catalog_store.dart';
import 'memory_cloud_deletion_outbox.dart';
import 'memory_document_store.dart';
import 'memory_illustration_store.dart';
import 'memory_narration_store.dart';
import 'memory_settings_store.dart';

/// Builds the single test composition root with in-memory defaults.
///
/// Supplying [narrationApi] installs narration with fake player, store, and
/// documents unless overridden. Without it, narration stays absent and the
/// voice source defaults to a fake cloud source. Teardown is the caller's job
/// because widget owners such as `ReaderApp` dispose their own controller.
Future<ReaderController> testController({
  List<CatalogBook> books = const [],
  CatalogStore? catalogStore,
  List<ImportCandidate> files = const [],
  SettingsStore? settingsStore,
  BookWordCounter? wordCounter,
  Directory? root,
  IllustrationStore? illustrationStore,
  TextIndexer? textIndexer,
  IllustrationApi? illustrationApi,
  CloudDeletionOutbox? illustrationDeletionOutbox,
  NarrationApi? narrationApi,
  NarrationSource? narrationSource,
  NarrationPlayer? narrationPlayer,
  NarrationStore? narrationStore,
  TextDocumentStore? narrationDocuments,
  CloudDeletionOutbox? narrationDeletionOutbox,
  CloudIdentity? cloudIdentity,
  AccountApi? accountApi,
  bool initialize = true,
}) async {
  assert(catalogStore == null || books.isEmpty);
  final directory =
      root ?? Directory('${Directory.systemTemp.path}/reader_test');
  final api = narrationApi;
  final controller = ReaderController(
    catalogStore: catalogStore ?? MemoryCatalogStore(books),
    settingsStore: settingsStore ?? MemorySettingsStore(),
    importer: BookImporter(root: directory),
    picker: FakePicker(files),
    illustrationStore: illustrationStore ?? MemoryIllustrationStore(),
    textIndexer: textIndexer ?? FakeTextIndexer(),
    wordCounter: wordCounter ?? FakeWordCounter(),
    illustrationApi: illustrationApi ?? FakeIllustrationApi(),
    illustrationDeletionOutbox:
        illustrationDeletionOutbox ?? MemoryCloudDeletionOutbox(),
    narrationSource:
        narrationSource ?? CloudNarrationSource(api ?? FakeNarrationApi()),
    narration: api == null
        ? null
        : (
            api: api,
            player: narrationPlayer ?? FakeNarrationPlayer(),
            store: narrationStore ?? MemoryNarrationStore(),
            documents: narrationDocuments ?? MemoryDocumentStore(),
          ),
    narrationDeletionOutbox:
        narrationDeletionOutbox ?? MemoryCloudDeletionOutbox(),
    cloudIdentity: cloudIdentity ?? (FakeCloudIdentity()..configured = false),
    accountApi: accountApi,
  );
  if (initialize) await controller.initialize();
  return controller;
}
