import 'package:flutter_test/flutter_test.dart';
import 'package:reader/cloud_deletion_queue.dart';

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
}
