// The small persistence contract is documented on its public types.
// ignore_for_file: public_member_api_docs

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
