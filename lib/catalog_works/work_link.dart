/// One catalog work as search and link responses describe it.
class WorkSummary {
  /// Captures the display fields of a work.
  const WorkSummary({
    required this.id,
    required this.title,
    required this.author,
    this.firstPublishYear,
    this.linked = false,
  });

  /// Server work identifier (20 lowercase hex characters), derived from the
  /// title and author, so the same book always has the same ID.
  final String id;

  /// Work title, usually as Open Library spells it.
  final String title;

  /// First author; may be empty.
  final String author;

  /// Year of first publication, when known, to tell same-titled works apart.
  final int? firstPublishYear;

  /// Whether some copy is already linked, so the work has a reference text.
  final bool linked;

  static final _id = RegExp(r'^[0-9a-f]{20}$');

  /// Decodes a server row; throws [FormatException] on malformed values.
  factory WorkSummary.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final title = json['title'];
    if (id is! String || !_id.hasMatch(id) || title is! String) {
      throw const FormatException('Invalid catalog work.');
    }
    return WorkSummary(
      id: id,
      title: title,
      author: json['author'] is String ? json['author'] as String : '',
      firstPublishYear: (json['firstPublishYear'] as num?)?.toInt(),
      linked: json['linked'] == true,
    );
  }

  /// Persisted form inside a [WorkLink].
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'firstPublishYear': firstPublishYear,
    'linked': linked,
  };
}

/// A local book's association with a catalog work for one account.
///
/// Persisted in `work-links.json`; [account] is the email the link was made
/// under, so a different signed-in account never sees it.
class WorkLink {
  /// Records a confirmed server link.
  const WorkLink({
    required this.bookHash,
    required this.account,
    required this.cloudBookId,
    required this.work,
    required this.score,
  });

  /// Import hash of the local catalog book.
  final String bookHash;

  /// Account email the server link belongs to.
  final String account;

  /// Server book ID shared with illustrations; deletion purges it.
  final String cloudBookId;

  /// The linked catalog work.
  final WorkSummary work;

  /// Share of identifiable paragraphs that matched, from 0.9 to 1.
  final double score;

  /// Decodes a persisted record; throws on malformed values.
  factory WorkLink.fromJson(Map<String, dynamic> json) => WorkLink(
    bookHash: json['bookHash'] as String,
    account: json['account'] as String,
    cloudBookId: json['cloudBookId'] as String,
    work: WorkSummary.fromJson((json['work'] as Map).cast<String, dynamic>()),
    score: (json['score'] as num).toDouble(),
  );

  /// Persisted form.
  Map<String, dynamic> toJson() => {
    'bookHash': bookHash,
    'account': account,
    'cloudBookId': cloudBookId,
    'work': work.toJson(),
    'score': score,
  };
}
