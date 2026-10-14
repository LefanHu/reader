import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/identity/cloud_failure_kind.dart';
import 'package:reader/identity/cloud_service_exception.dart';
import 'package:reader/importing/import_candidate.dart';
import 'package:reader/text/document_store.dart';
import 'package:reader/text/text_block.dart';
import 'package:reader/text/text_section.dart';
import 'package:reader/text_identity/text_identity_coordinator.dart';

import 'support/cloud_identity_fake.dart';
import 'support/fake_illustration_api.dart';
import 'support/fake_text_identity_api.dart';
import 'support/memory_document_store.dart';
import 'support/test_controller.dart';

CatalogBook _book(String letter) => CatalogBook(
  wordCount: 0,
  hash: letter * 64,
  fileName: '$letter.epub',
  path: '$letter.epub',
  title: 'Book $letter',
  authors: const [],
  addedAt: DateTime.utc(2026),
);

final _a = _book('a');
final _b = _book('b');

final _documents = MemoryDocumentStore(
  sections: const [
    TextSection(
      id: 's0',
      blocks: [TextBlock(id: 'b', text: 'It was a bright cold day in April.')],
    ),
  ],
);

final _text = utf8.encode('A paragraph long enough to fingerprint.');

const _offline = CloudServiceException(
  CloudFailureKind.offline,
  'Connect to the internet to use cloud features.',
);

void main() {
  late Directory root;
  late FakeTextIdentityApi api;
  late List<CatalogBook> books;
  String? email;
  var changes = 0;

  TextIdentityCoordinator coordinator({TextDocumentStore? documents}) {
    final identities = TextIdentityCoordinator(
      api: api,
      root: root,
      account: () => email,
      books: () => books,
      changed: () => changes++,
      documents: documents ?? _documents,
    );
    addTearDown(identities.dispose);
    return identities;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('text_identities');
    api = FakeTextIdentityApi();
    books = [_a, _b];
    email = 'reader@example.test';
    changes = 0;
  });
  tearDown(() => root.delete(recursive: true));

  test('a nudge identifies every book once and survives restart', () async {
    final identities = coordinator()..nudge();
    await identities.idle;
    expect(api.calls, [_a.hash, _b.hash]);
    expect(identities.identityFor(_a)?.cloudBookId, 'a' * 40);
    expect(
      identities.identityFor(_b)?.textId,
      FakeTextIdentityApi.textIdFor(api.sent[_b.hash]!),
    );
    expect(changes, 2);

    identities.nudge();
    await identities.idle;
    expect(api.calls, hasLength(2));

    final restored = coordinator();
    await restored.restore();
    restored.nudge();
    await restored.idle;
    expect(restored.identityFor(_a)?.score, 1);
    expect(api.calls, hasLength(2));
  });

  test('signed out identifies nothing and hides other accounts', () async {
    final identities = coordinator()..nudge();
    await identities.idle;
    email = null;
    expect(identities.identityFor(_a), isNull);
    identities.nudge();
    await identities.idle;
    expect(api.calls, hasLength(2));

    email = 'other@example.test';
    expect(identities.identityFor(_a), isNull);
    identities.nudge();
    await identities.idle;
    expect(api.calls, hasLength(4));
    expect(identities.identityFor(_a)?.account, 'other@example.test');
  });

  test('a cloud failure stops the drain and the next nudge resumes', () async {
    api.failure = _offline;
    final identities = coordinator()..nudge();
    await identities.idle;
    expect(api.calls, [_a.hash]);
    expect(identities.identityFor(_a), isNull);

    api.failure = null;
    identities.nudge();
    await identities.idle;
    expect(identities.identityFor(_a), isNotNull);
    expect(identities.identityFor(_b), isNotNull);
  });

  test('an unreadable book skips only itself', () async {
    final identities = coordinator(documents: _FailingFirstStore(_a.path))
      ..nudge();
    await identities.idle;
    expect(api.calls, [_b.hash]);
    expect(identities.identityFor(_b), isNotNull);
  });

  test('a nudge during a drain runs one more pass for new books', () async {
    books = [_a];
    final hold = api.hold = Completer<void>();
    final identities = coordinator()..nudge();
    await pumpEventQueue();
    books = [_a, _b];
    identities.nudge();
    hold.complete();
    await identities.idle;
    expect(api.calls, [_a.hash, _b.hash]);
  });

  test('an account change mid-request drops the late result', () async {
    books = [_a];
    final hold = api.hold = Completer<void>();
    final identities = coordinator()..nudge();
    await pumpEventQueue();
    identities.invalidateAccount();
    hold.complete();
    await identities.idle;
    expect(identities.identityFor(_a), isNull);
    expect(identities.cloudBookIdFor(_a), isNull);
    expect(changes, 0);
  });

  test('deleting a book mid-request drops the late result', () async {
    books = [_a];
    final hold = api.hold = Completer<void>();
    final identities = coordinator()..nudge();
    await pumpEventQueue();
    books = [];
    await identities.forget(_a);
    hold.complete();
    await identities.idle;
    expect(identities.cloudBookIdFor(_a), isNull);
    expect(File('${root.path}/text-identities.json').existsSync(), isFalse);
  });

  test('a malformed persisted record drops only itself', () async {
    final identities = coordinator()..nudge();
    await identities.idle;
    final file = File('${root.path}/text-identities.json');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    (json['identities'] as List).add({'bookHash': 'broken'});
    file.writeAsStringSync(jsonEncode(json));
    final restored = coordinator();
    await restored.restore();
    expect(restored.identityFor(_a), isNotNull);
    expect(restored.identityFor(_b), isNotNull);
  });

  test('deleting a book purges its identified server book', () async {
    final illustrations = FakeIllustrationApi(configured: true);
    final controller = await testController(
      books: [_a],
      illustrationApi: illustrations,
      cloudIdentity: FakeCloudIdentity()..email = email,
      identities: (api: api, root: root, documents: _documents),
    );
    addTearDown(controller.dispose);
    await controller.identities!.idle;
    expect(controller.identities!.cloudBookIdFor(_a), 'a' * 40);
    await controller.delete(_a);
    await controller.drainCloudDeletions();
    expect(illustrations.deletedBooks, contains('a' * 40));
    expect(controller.identities!.cloudBookIdFor(_a), isNull);
  });

  test('an import while signed in is identified in the background', () async {
    final controller = await testController(
      root: root,
      files: [
        ImportCandidate(
          name: 'Imported.txt',
          size: _text.length,
          readBytes: () async => _text,
        ),
      ],
      cloudIdentity: FakeCloudIdentity()..email = email,
      identities: (api: api, root: root, documents: null),
    );
    addTearDown(controller.dispose);
    await controller.identities!.idle;
    expect(api.calls, isEmpty);
    await controller.catalog.pickAndImport();
    await controller.identities!.idle;
    final book = controller.catalog.books.single;
    expect(api.calls, [book.hash]);
    expect(controller.identities!.identityFor(book), isNotNull);
  });
}

/// Fails to load [failing]; every other path reads the default fixture.
class _FailingFirstStore extends MemoryDocumentStore {
  _FailingFirstStore(this.failing) : super(sections: _documents.sections);
  final String failing;

  @override
  Future<TextSection> loadSection(String sourcePath, String id) async {
    if (sourcePath == failing) throw const FileSystemException('unreadable');
    return super.loadSection(sourcePath, id);
  }
}
