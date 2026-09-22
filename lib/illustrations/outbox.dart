// The small persistence contract is documented on its public types.
// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:io';

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
    : _file = File('${catalogRoot.path}/illustration-deletions.json');

  final File _file;

  @override
  Future<List<PendingBookDeletion>> load() async {
    for (final candidate in [
      _file,
      File('${_file.path}.tmp'),
      File('${_file.path}.bak'),
    ]) {
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
  Future<void> enqueue(String cloudBookId) async {
    final items = await load();
    if (items.any((item) => item.cloudBookId == cloudBookId)) return;
    await _save([
      ...items,
      PendingBookDeletion(cloudBookId: cloudBookId, queuedAt: DateTime.now()),
    ]);
  }

  @override
  Future<void> remove(String cloudBookId) async {
    final items = await load();
    await _save(
      items.where((item) => item.cloudBookId != cloudBookId).toList(),
    );
  }

  Future<void> _save(List<PendingBookDeletion> items) async {
    await _file.parent.create(recursive: true);
    final temporary = File('${_file.path}.tmp');
    final backup = File('${_file.path}.bak');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'items': items.map((item) => item.toJson()).toList(),
      }),
      flush: true,
    );
    if (await backup.exists()) await backup.delete();
    if (await _file.exists()) await _file.rename(backup.path);
    await temporary.rename(_file.path);
    if (await backup.exists()) await backup.delete();
  }
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
