import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/illustrations/file_illustration_store.dart';

void main() {
  late Directory root;
  late Directory visuals;
  late CatalogBook book;
  late FileIllustrationStore store;
  final hash = 'b' * 64;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('illustration-reset-');
    addTearDown(() => root.delete(recursive: true));
    final owned = Directory('${root.path}/books/$hash');
    visuals = Directory('${owned.path}/visuals');
    await Directory('${visuals.path}/images').create(recursive: true);
    final source = File('${owned.path}/book.epub');
    await source.writeAsString('source');
    book = CatalogBook(
      hash: hash,
      fileName: 'book.epub',
      path: source.path,
      title: 'T',
      authors: const [],
      addedAt: DateTime.utc(2026),
    );
    store = FileIllustrationStore(root);
  });

  Future<void> write(String name, Map<String, Object?> json) =>
      File('${visuals.path}/$name').writeAsString(jsonEncode(json));

  Map<String, Object?> manifest(Object? version) => {
    'version': ?version,
    'bookHash': hash,
  };

  test(
    'old manifest discards only visuals and leaves a fresh disabled v2',
    () async {
      await write('manifest.json', manifest(1));
      await write('index.json', {'version': 1});
      await File('${visuals.path}/images/old.webp').writeAsString('x');

      final loaded = await store.loadManifest(book);

      expect(loaded.enabled, isFalse);
      expect(loaded.scenes, isEmpty);
      expect(File('${visuals.path}/images/old.webp').existsSync(), isFalse);
      expect(File(book.path).existsSync(), isTrue);
      expect((await store.loadManifest(book)).version, 2);
    },
  );

  test('version-less backup alone is obsolete', () async {
    await write('manifest.json.bak', manifest(null));
    await File('${visuals.path}/images/old.png').writeAsString('x');

    await store.loadManifest(book);

    expect(File('${visuals.path}/images/old.png').existsSync(), isFalse);
  });

  test('valid recovered v2 survives an obsolete v1 backup', () async {
    await store.saveManifest(book, (await store.loadManifest(book)));
    await write('manifest.json.bak', manifest(1));
    await File('${visuals.path}/images/keep.png').writeAsString('x');

    await store.loadManifest(book);

    expect(File('${visuals.path}/images/keep.png').existsSync(), isTrue);
  });

  test('future schema is left untouched', () async {
    await write('manifest.json', manifest(3));
    await File('${visuals.path}/images/future.png').writeAsString('x');

    final loaded = await store.loadManifest(book);

    expect(loaded.enabled, isFalse);
    expect(File('${visuals.path}/images/future.png').existsSync(), isTrue);
  });

  test('a symlink inside visuals blocks discard', () async {
    await write('manifest.json', manifest(1));
    final outside = await Directory.systemTemp.createTemp('outside-');
    addTearDown(() => outside.delete(recursive: true));
    await File('${outside.path}/secret').writeAsString('s');
    await Link('${visuals.path}/images/link').create(outside.path);

    await store.loadManifest(book);

    expect(File('${outside.path}/secret').existsSync(), isTrue);
    expect(File('${visuals.path}/manifest.json').existsSync(), isTrue);
  });

  test('another book hash is not treated as owned', () async {
    await File('${visuals.path}/manifest.json')
        .writeAsString(jsonEncode({'version': 1, 'bookHash': 'c' * 64}));
    await store.loadManifest(book);
    expect(File('${visuals.path}/manifest.json').existsSync(), isTrue);
  });
}
