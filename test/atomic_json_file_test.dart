import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/atomic_json_file.dart';

void main() {
  test(
    'failed writes propagate without blocking a later write to the same path',
    () async {
      final root = await Directory.systemTemp.createTemp('atomic_json_failure');
      addTearDown(() => root.delete(recursive: true));
      final parent = File('${root.path}/blocked');
      await parent.writeAsString('not a directory');
      final file = File('${parent.path}/value.json');
      final first = AtomicJsonFile(file);
      await expectLater(
        first.write({'value': 1}),
        throwsA(isA<FileSystemException>()),
      );
      await parent.delete();
      await AtomicJsonFile(file).write({'value': 2});
      expect(jsonDecode(await file.readAsString()), {'value': 2});
    },
  );

  test(
    'queued writes retain the snapshot from when they were requested',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'atomic_json_snapshot',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/value.json');
      final atomic = AtomicJsonFile(file);
      final value = {
        'items': [1],
      };
      final save = atomic.write(value);
      value['items']!.add(2);
      await save;
      expect(jsonDecode(await file.readAsString()), {
        'items': [1],
      });
    },
  );
}
