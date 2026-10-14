/// Which shared text a local book is, as the server identified it for one
/// account.
///
/// Persisted in `text-identities.json`; [account] is the email it was
/// identified under, so another signed-in account never sees it.
class TextIdentity {
  /// Records a server identification.
  const TextIdentity({
    required this.bookHash,
    required this.account,
    required this.cloudBookId,
    required this.textId,
    required this.score,
  });

  /// Import hash of the local catalog book.
  final String bookHash;

  /// Account email the identification belongs to.
  final String account;

  /// Server book ID shared with illustrations; deletion purges it.
  final String cloudBookId;

  /// Shared text (20 lowercase hex characters) every matching copy resolves to.
  final String textId;

  /// Share of this copy's identifiable paragraphs found in the shared text's
  /// reference, from 0.9 to 1.
  final double score;

  static final _textId = RegExp(r'^[0-9a-f]{20}$');

  /// Decodes a persisted record; throws on malformed values.
  factory TextIdentity.fromJson(Map<String, dynamic> json) {
    final textId = json['textId'] as String;
    if (!_textId.hasMatch(textId)) {
      throw const FormatException('Invalid text identity.');
    }
    return TextIdentity(
      bookHash: json['bookHash'] as String,
      account: json['account'] as String,
      cloudBookId: json['cloudBookId'] as String,
      textId: textId,
      score: (json['score'] as num).toDouble(),
    );
  }

  /// Persisted form.
  Map<String, dynamic> toJson() => {
    'bookHash': bookHash,
    'account': account,
    'cloudBookId': cloudBookId,
    'textId': textId,
    'score': score,
  };
}
