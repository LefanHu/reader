import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../account/http_account_api.dart';
import '../book_analysis/file_analysis_store.dart';
import '../book_analysis/http_book_analysis_api.dart';
import '../catalog/file_catalog_store.dart';
import '../catalog_works/http_works_api.dart';
import '../file_cloud_deletion_outbox.dart';
import '../identity/firebase_cloud_identity.dart';
import '../illustrations/file_illustration_store.dart';
import '../illustrations/http_illustration_api.dart';
import '../importing/book_importer.dart';
import '../importing/native_book_picker.dart';
import '../narration/file_narration_store.dart';
import '../narration/http_narration_api.dart';
import '../narration/narration_provider.dart';
import '../narration/native_narration_player.dart';
import '../preferences/preference_settings_store.dart';
import 'reader_controller.dart';

/// Composition root: builds the production dependency graph of file stores,
/// native services and cloud APIs, then restores persisted state.
///
/// Tests compose [ReaderController] directly with their own boundaries; only
/// `main` uses this graph.
Future<ReaderController> createProductionController() async {
  final store = await FileCatalogStore.create();
  // Native synthesis binds an existing private root before any book is opened.
  await store.root.create(recursive: true);
  final identity = FirebaseCloudIdentity();
  // One app-lifetime connection pool serves every cloud feature API.
  final client = http.Client();
  final narrationApi = HttpNarrationApi(identity: identity, client: client);
  final source = await createNarrationSource(
    selectNarrationProvider(defaultTargetPlatform),
    root: store.root,
    api: narrationApi,
  );
  final controller = ReaderController(
    cloudIdentity: identity,
    accountApi: HttpAccountApi(identity: identity, client: client),
    analysis: (
      api: HttpBookAnalysisApi(identity: identity, client: client),
      store: FileAnalysisStore(store.root),
      documents: null,
    ),
    works: (
      api: HttpWorksApi(identity: identity, client: client),
      root: store.root,
      documents: null,
    ),
    narrationSource: source,
    narration: (
      api: narrationApi,
      player: await NativeNarrationPlayer.create(),
      store: FileNarrationStore(store.root),
      documents: null,
    ),
    narrationDeletionOutbox: FileCloudDeletionOutbox(
      store.root,
      fileName: 'narration-deletions.json',
    ),
    catalogStore: store,
    settingsStore: PreferenceSettingsStore(),
    importer: BookImporter(root: store.root),
    picker: NativeBookPicker(),
    illustrationDeletionOutbox: FileCloudDeletionOutbox(
      store.root,
      fileName: 'illustration-deletions.json',
    ),
    illustrationStore: FileIllustrationStore(store.root),
    illustrationApi: HttpIllustrationApi(identity: identity, client: client),
  );
  // The mounted app supplies the actual native lifecycle before any dispatch.
  controller.setAppResumed(false);
  await controller.initialize();
  return controller;
}
