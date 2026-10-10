// The small persistence contract is documented on its public types.
// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:io';

import '../atomic_json_file.dart';
import 'outbox.dart';
import 'pending_book_deletion.dart';

/// Atomic JSON outbox stored outside per-book directories.
class FileIllustrationDeletionOutbox implements IllustrationDeletionOutbox {
  FileIllustrationDeletionOutbox(
    Directory catalogRoot, {
    String fileName = 'illustration-deletions.json',
  }) : _file = AtomicJsonFile(File('${catalogRoot.path}/$fileName'));

  final AtomicJsonFile _file;

  @override
  Future<List<PendingBookDeletion>> load() async {
    for (final candidate in _file.generations) {
      if (!await candidate.exists()) continue;
      try {
        final json = jsonDecode(await candidate.readAsString());
        if (json is! Map || json['version'] != 1 || json['items'] is! List) {
          continue;
        }
        return (json['items'] as List<dynamic>)
            .whereType<Map>()
            .map(
              (item) =>
                  PendingBookDeletion.fromJson(item.cast<String, dynamic>()),
            )
            .toList();
      } on Object {
        continue;
      }
    }
    return [];
  }

  @override
  Future<void> enqueue(String cloudBookId) => _file.update(() async {
    final items = await load();
    if (items.any((item) => item.cloudBookId == cloudBookId)) return null;
    return _json([
      ...items,
      PendingBookDeletion(cloudBookId: cloudBookId, queuedAt: DateTime.now()),
    ]);
  });

  @override
  Future<void> remove(String cloudBookId) => _file.update(() async {
    final items = await load();
    return _json(
      items.where((item) => item.cloudBookId != cloudBookId).toList(),
    );
  });

  Map<String, dynamic> _json(List<PendingBookDeletion> items) => {
    'version': 1,
    'items': items.map((item) => item.toJson()).toList(),
  };
}
