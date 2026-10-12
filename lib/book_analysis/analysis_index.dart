import '../text/text_position.dart';
import 'analysis_span.dart';

/// Supported alias mapping avoids rewriting immutable extraction records.
class AnalysisEntityMapping {
  /// Canonical identity is earliest evidence identity, not latest name.
  const AnalysisEntityMapping({
    required this.entityId,
    required this.canonicalEntityId,
    required this.evidence,
    required this.revealAt,
  });

  /// Original extraction identity.
  final String entityId;

  /// Evidence-supported reconciled identity.
  final String canonicalEntityId;

  /// Nonempty support for the identity decision.
  final List<AnalysisSpan> evidence;

  /// Reader reveal anchor for the identity relation.
  final AnalysisPosition revealAt;

  /// Durable mapping with disclosure provenance.
  Map<String, dynamic> toJson() => {
    'entityId': entityId,
    'canonicalEntityId': canonicalEntityId,
    'evidence': evidence.map((span) => span.toJson()).toList(),
    'revealAt': revealAt.toJson(),
  };

  /// Restores supported reconciliation without resolving ambiguous candidates.
  factory AnalysisEntityMapping.fromJson(Map<String, dynamic> json) =>
      AnalysisEntityMapping(
        entityId: json['entityId'] as String,
        canonicalEntityId: json['canonicalEntityId'] as String,
        evidence: _evidence(json['evidence']),
        revealAt: TextPosition.fromJson(
          (json['revealAt'] as Map).cast<String, dynamic>(),
        ),
      );
}

/// Supported equivalence between extraction-local story-time nodes.
class AnalysisTimeMapping {
  /// Mappings do not impose an order on incomparable nodes.
  const AnalysisTimeMapping({
    required this.timeId,
    required this.canonicalTimeId,
    required this.evidence,
  });

  /// Original time identity.
  final String timeId;

  /// Evidence-supported canonical time identity.
  final String canonicalTimeId;

  /// Nonempty supporting temporal evidence.
  final List<AnalysisSpan> evidence;

  /// Durable temporal equivalence.
  Map<String, dynamic> toJson() => {
    'timeId': timeId,
    'canonicalTimeId': canonicalTimeId,
    'evidence': evidence.map((span) => span.toJson()).toList(),
  };

  /// Restores equivalence without creating calendar dates.
  factory AnalysisTimeMapping.fromJson(Map<String, dynamic> json) =>
      AnalysisTimeMapping(
        timeId: json['timeId'] as String,
        canonicalTimeId: json['canonicalTimeId'] as String,
        evidence: _evidence(json['evidence']),
      );
}

/// Explicit assertion supersession, preserving the entry that established it.
class AnalysisSupersession {
  /// Contradictory facts are not implicitly superseded by narrative order.
  const AnalysisSupersession({
    required this.assertionId,
    required this.supersedesAssertionIds,
    required this.entryId,
  });

  /// Newly established assertion.
  final String assertionId;

  /// Assertions explicitly ended/replaced by supported change.
  final List<String> supersedesAssertionIds;

  /// Source change record proving the supersession.
  final String entryId;

  /// Durable change provenance.
  Map<String, dynamic> toJson() => {
    'assertionId': assertionId,
    'supersedesAssertionIds': supersedesAssertionIds,
    'entryId': entryId,
  };

  /// Restores explicit change provenance.
  factory AnalysisSupersession.fromJson(Map<String, dynamic> json) =>
      AnalysisSupersession(
        assertionId: json['assertionId'] as String,
        supersedesAssertionIds: List.unmodifiable(
          (json['supersedesAssertionIds'] as List).cast<String>(),
        ),
        entryId: json['entryId'] as String,
      );
}

/// Per-subject temporal retrieval index, not a latest-state truth snapshot.
class AnalysisSubjectIndex {
  /// Facts remain owned by their supported subject, including group subjects.
  const AnalysisSubjectIndex({
    required this.subjectId,
    required this.assertionIds,
    required this.entryIds,
    required this.supersessions,
  });

  /// Entity whose supported temporal records are indexed.
  final String subjectId;

  /// All relevant assertions, including conflicting/uncertain facts.
  final List<String> assertionIds;

  /// Supporting timeline record identities.
  final List<String> entryIds;

  /// Explicit changes with source provenance.
  final List<AnalysisSupersession> supersessions;

  /// Durable temporal lookup shard.
  Map<String, dynamic> toJson() => {
    'subjectId': subjectId,
    'assertionIds': assertionIds,
    'entryIds': entryIds,
    'supersessions': supersessions.map((item) => item.toJson()).toList(),
  };

  /// Restores indexes without applying group properties to arbitrary members.
  factory AnalysisSubjectIndex.fromJson(Map<String, dynamic> json) =>
      AnalysisSubjectIndex(
        subjectId: json['subjectId'] as String,
        assertionIds: List.unmodifiable(
          (json['assertionIds'] as List).cast<String>(),
        ),
        entryIds: List.unmodifiable((json['entryIds'] as List).cast<String>()),
        supersessions: List.unmodifiable(
          (json['supersessions'] as List).map(
            (item) => AnalysisSupersession.fromJson(
              (item as Map).cast<String, dynamic>(),
            ),
          ),
        ),
      );
}

List<AnalysisSpan> _evidence(dynamic value) {
  final spans = (value as List)
      .map(
        (item) => AnalysisSpan.fromJson((item as Map).cast<String, dynamic>()),
      )
      .toList();
  if (spans.isEmpty) throw const FormatException('Missing mapping evidence.');
  return List.unmodifiable(spans);
}
