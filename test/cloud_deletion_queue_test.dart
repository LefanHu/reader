import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/cloud_deletion_queue.dart';
import 'package:reader/file_cloud_deletion_outbox.dart';

import 'support/memory_cloud_deletion_outbox.dart';

void main() {
  test('concurrent drains delete each pending ID once', () async {
    final outbox = MemoryCloudDeletionOutbox();
    await outbox.enqueue('a');
    await outbox.enqueue('b');
    final deleted = <String>[];
    final queue = CloudDeletionQueue(
      outbox: outbox,
      ready: () async => true,
      delete: (id) async {
        await Future<void>.delayed(Duration.zero);
        deleted.add(id);
      },
    );
    await Future.wait([queue.drain(), queue.drain()]);
    expect(deleted, ['a', 'b']);
    expect(await queue.hasPending, isFalse);
  });

  test('a failed deletion stays durable in the outbox', () async {
    final outbox = MemoryCloudDeletionOutbox();
    await outbox.enqueue('a');
    await outbox.enqueue('b');
    final queue = CloudDeletionQueue(
      outbox: outbox,
      ready: () async => true,
      delete: (id) async {
        if (id == 'a') throw StateError('Offline');
      },
    );
    await queue.drain();
    expect((await outbox.load()).map((item) => item.cloudBookId), ['a']);
  });

  test('an unready session deletes nothing', () async {
    final outbox = MemoryCloudDeletionOutbox();
    await outbox.enqueue('a');
    final deleted = <String>[];
    final queue = CloudDeletionQueue(
      outbox: outbox,
      ready: () async => false,
      delete: (id) async => deleted.add(id),
    );
    await queue.drain();
    expect(deleted, isEmpty);
    expect(await queue.hasPending, isTrue);
  });

  test('a malformed outbox record never drops the valid receipts', () async {
    final root = await Directory.systemTemp.createTemp('outbox');
    addTearDown(() => root.delete(recursive: true));
    File('${root.path}/deletions.json').writeAsStringSync(
      jsonEncode({
        'items': [
          {'cloudBookId': 'a', 'queuedAt': '2026-01-01T00:00:00Z'},
          {'cloudBookId': 7},
        ],
      }),
    );
    final outbox = FileCloudDeletionOutbox(root, fileName: 'deletions.json');
    expect((await outbox.load()).map((item) => item.cloudBookId), ['a']);
    await outbox.enqueue('b');
    expect((await outbox.load()).map((item) => item.cloudBookId), ['a', 'b']);
  });
}
