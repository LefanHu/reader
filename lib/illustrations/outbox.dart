// The small persistence contract is documented on its public types.
// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:io';

import '../atomic_json_file.dart';

/// A cloud book deletion that must be retried after connectivity returns.
class PendingBookDeletion {
  const PendingBookDeletion({
    required this.cloudBookId,
    required this.queuedAt,
  });

  final String cloudBookId;
  final DateTime queuedAt;

  Map<String, dynamic> toJson() => {
    'cloudBookId': cloudBookId,
    'queuedAt': queuedAt.toUtc().toIso8601String(),
  };

  factory PendingBookDeletion.fromJson(Map<String, dynamic> json) =>
      PendingBookDeletion(
        cloudBookId: json['cloudBookId'] as String,
        queuedAt: DateTime.parse(json['queuedAt'] as String),
      );
}

/// Durable boundary for privacy-sensitive cloud deletion retries.
abstract interface class IllustrationDeletionOutbox {
  Future<List<PendingBookDeletion>> load();
  Future<void> enqueue(String cloudBookId);
  Future<void> remove(String cloudBookId);
}

/// Atomic JSON outbox stored outside per-book directories.
class FileIllustrationDeletionOutbox implements IllustrationDeletionOutbox {
  FileIllustrationDeletionOutbox(Directory catalogRoot)
    : _file = AtomicJsonFile(
        File('${catalogRoot.path}/illustration-deletions.json'),
      );

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

/// In-memory default for custom controller graphs that do not own a root.
class MemoryIllustrationDeletionOutbox implements IllustrationDeletionOutbox {
  final List<PendingBookDeletion> _items = [];

  @override
  Future<void> enqueue(String cloudBookId) async {
    if (_items.any((item) => item.cloudBookId == cloudBookId)) return;
    _items.add(
      PendingBookDeletion(cloudBookId: cloudBookId, queuedAt: DateTime.now()),
    );
  }

  @override
  Future<List<PendingBookDeletion>> load() async => List.of(_items);

  @override
  Future<void> remove(String cloudBookId) async {
    _items.removeWhere((item) => item.cloudBookId == cloudBookId);
  }
}
