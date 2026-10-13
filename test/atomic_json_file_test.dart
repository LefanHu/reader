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

  test('read skips a symlinked generation and reports recovery', () async {
    final root = await Directory.systemTemp.createTemp('atomic_json_read');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/value.json');
    final atomic = AtomicJsonFile(file);
    final outside = File('${root.path}/outside.json')
      ..writeAsStringSync(jsonEncode({'value': 'outside'}));
    Link('${file.path}.tmp').createSync(outside.path);
    File('${file.path}.bak').writeAsStringSync(jsonEncode({'value': 'bak'}));

    final skipped = await atomic.read((json) => json['value'] as String?);
    expect(skipped?.value, 'bak');
    expect(skipped?.recovered, isTrue);

    Link('${file.path}.tmp').deleteSync();
    File('${file.path}.tmp').writeAsStringSync(jsonEncode({'value': 'tmp'}));
    file.writeAsStringSync('{broken');
    final recovered = await atomic.read((json) => json['value'] as String?);
    expect(recovered?.value, 'tmp');
    expect(recovered?.recovered, isTrue);
  });

  test('write never follows a linked temporary generation', () async {
    final root = await Directory.systemTemp.createTemp('atomic_json_link');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/value.json');
    final outside = File('${root.path}/outside.json')..writeAsStringSync('{}');
    Link('${file.path}.tmp').createSync(outside.path);

    await expectLater(
      AtomicJsonFile(file).write({'value': 1}),
      throwsFormatException,
    );
    expect(outside.readAsStringSync(), '{}');
    expect(file.existsSync(), isFalse);
  });

  test('write without createParent leaves a deleted parent deleted', () async {
    final root = await Directory.systemTemp.createTemp('atomic_json_parent');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/gone/value.json');

    await expectLater(
      AtomicJsonFile(file, createParent: false).write({'value': 1}),
      throwsA(isA<FileSystemException>()),
    );
    expect(Directory('${root.path}/gone').existsSync(), isFalse);
  });
}
