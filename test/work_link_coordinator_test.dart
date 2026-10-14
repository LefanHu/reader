import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/catalog_works/work_link.dart';
import 'package:reader/catalog_works/work_link_coordinator.dart';
import 'package:reader/catalog_works/work_text.dart';
import 'package:reader/identity/cloud_failure_kind.dart';
import 'package:reader/identity/cloud_service_exception.dart';
import 'package:reader/text/text_block.dart';
import 'package:reader/text/text_section.dart';

import 'support/fake_works_api.dart';
import 'support/memory_document_store.dart';
import 'support/cloud_identity_fake.dart';
import 'support/fake_illustration_api.dart';
import 'support/test_controller.dart';

final _book = CatalogBook(
  wordCount: 0,
  hash: 'a' * 64,
  fileName: 'book.epub',
  path: 'book.epub',
  title: 'Nineteen Eighty-Four',
  authors: const ['George Orwell'],
  addedAt: DateTime.utc(2026),
);

final _documents = MemoryDocumentStore(
  sections: const [
    TextSection(
      id: 's0',
      blocks: [TextBlock(id: 'b', text: 'It was a bright cold day in April.')],
    ),
  ],
);

void main() {
  late Directory root;
  late FakeWorksApi api;
  String? email;
  var changes = 0;

  WorkLinkCoordinator coordinator() => WorkLinkCoordinator(
    api: api,
    root: root,
    account: () => email,
    changed: () => changes++,
    documents: _documents,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('work_links');
    api = FakeWorksApi();
    email = 'reader@example.test';
    changes = 0;
  });
  tearDown(() => root.delete(recursive: true));

  Future<WorkLink?> linkOrwell(WorkLinkCoordinator works) =>
      works.link(_book, title: 'Nineteen Eighty-Four', author: 'George Orwell');

  test('linking records the link and survives restart', () async {
    final works = coordinator();
    final link = await linkOrwell(works);
    expect(link?.work.title, 'Nineteen Eighty-Four');
    expect(works.linkFor(_book)?.cloudBookId, 'a' * 40);
    expect(api.calls, ['link:Nineteen Eighty-Four']);
    expect(changes, 1);

    final restored = coordinator();
    await restored.restore();
    expect(restored.linkFor(_book)?.work.title, 'Nineteen Eighty-Four');
  });

  test(
    'a copy that does not match the reference fails without a link',
    () async {
      api.references[FakeWorksApi.idFor(
        'Nineteen Eighty-Four',
        'George Orwell',
      )] = base64Encode(
        workParagraphFingerprint('A different translation.'),
      );
      final works = coordinator();
      await expectLater(
        linkOrwell(works),
        throwsA(
          isA<CloudServiceException>().having(
            (error) => error.statusCode,
            'statusCode',
            422,
          ),
        ),
      );
      expect(works.linkFor(_book), isNull);
    },
  );

  test(
    'a link is hidden from another account until the server confirms it',
    () async {
      final works = coordinator();
      await linkOrwell(works);
      email = 'other@example.test';
      expect(works.linkFor(_book), isNull);
      api.links.clear();
      expect(await works.refresh(_book), isNull);
      expect(works.cloudBookIdFor(_book), isNull);
    },
  );

  test('an account change during an action drops its late result', () async {
    final works = coordinator();
    final hold = api.hold = Completer<void>();
    final pending = linkOrwell(works);
    await pumpEventQueue();
    works.invalidateAccount();
    hold.complete();
    expect(await pending, isNull);
    expect(works.linkFor(_book), isNull);
    expect(changes, 0);
  });

  test('forgetting a deleted book retires its in-flight action', () async {
    final works = coordinator();
    final hold = api.hold = Completer<void>();
    final pending = linkOrwell(works);
    await pumpEventQueue();
    await works.forget(_book);
    hold.complete();
    expect(await pending, isNull);
    expect(works.cloudBookIdFor(_book), isNull);
  });

  test('offline failures propagate for an inline retry', () async {
    api.failure = const CloudServiceException(
      CloudFailureKind.offline,
      'Connect to the internet to use cloud features.',
    );
    await expectLater(
      coordinator().search('orwell'),
      throwsA(isA<CloudServiceException>()),
    );
    expect((await coordinator().search('  ')).works, isEmpty);
  });

  test('a malformed persisted record drops only itself', () async {
    final works = coordinator();
    await linkOrwell(works);
    final file = File('${root.path}/work-links.json');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    (json['links'] as List).add({'bookHash': 'broken'});
    file.writeAsStringSync(jsonEncode(json));
    final restored = coordinator();
    await restored.restore();
    expect(restored.linkFor(_book)?.work.title, 'Nineteen Eighty-Four');
  });

  test('deleting a book purges its linked server book', () async {
    final illustrations = FakeIllustrationApi(configured: true);
    final controller = await testController(
      books: [_book],
      illustrationApi: illustrations,
      cloudIdentity: FakeCloudIdentity()..email = email,
      works: (api: api, root: root, documents: _documents),
    );
    addTearDown(controller.dispose);
    await linkOrwell(controller.works!);
    await controller.delete(_book);
    await controller.drainCloudDeletions();
    expect(illustrations.deletedBooks, contains('a' * 40));
    expect(controller.works!.cloudBookIdFor(_book), isNull);
  });
}
