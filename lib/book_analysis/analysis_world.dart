import 'analysis_span.dart';

/// Selected supported environmental assertions, not generated background lore.
class WorldBaseline {
  /// Applicability is explicit; null time endpoints remain unknown.
  const WorldBaseline({
    required this.id,
    required this.assertionIds,
    required this.evidence,
    required this.validFromTimeId,
    required this.validUntilTimeId,
  });

  /// Stable baseline record identity.
  final String id;

  /// Supported assertions selected for this applicable baseline.
  final List<String> assertionIds;

  /// Nonempty evidence supporting baseline selection.
  final List<AnalysisSpan> evidence;

  /// Established start; unknown is not beginning of book.
  final String? validFromTimeId;

  /// Established end; unknown is not end of book.
  final String? validUntilTimeId;

  /// Durable evidence-only baseline.
  Map<String, dynamic> toJson() => {
    'id': id,
    'assertionIds': assertionIds,
    'evidence': evidence.map((span) => span.toJson()).toList(),
    'validFromTimeId': validFromTimeId,
    'validUntilTimeId': validUntilTimeId,
  };

  /// Restores selected facts without inventing missing applicability.
  factory WorldBaseline.fromJson(Map<String, dynamic> json) => WorldBaseline(
    id: json['id'] as String,
    assertionIds: List.unmodifiable(
      (json['assertionIds'] as List).cast<String>(),
    ),
    evidence: _evidence(json['evidence']),
    validFromTimeId: json['validFromTimeId'] as String?,
    validUntilTimeId: json['validUntilTimeId'] as String?,
  );
}

/// Textual location relations; no invented coordinates or rendered map data.
class WorldMap {
  /// Relational assertions must be directly supported by source evidence.
  const WorldMap({
    required this.id,
    required this.locationEntityIds,
    required this.relationAssertionIds,
    required this.evidence,
  });

  /// Stable map record identity.
  final String id;

  /// Supported location identities present in this map shard.
  final List<String> locationEntityIds;

  /// Evidence-backed inside/adjacent/directional relation assertion identities.
  final List<String> relationAssertionIds;

  /// Nonempty support for this textual map.
  final List<AnalysisSpan> evidence;

  /// Persists supported relations, never inferred geography.
  Map<String, dynamic> toJson() => {
    'id': id,
    'locationEntityIds': locationEntityIds,
    'relationAssertionIds': relationAssertionIds,
    'evidence': evidence.map((span) => span.toJson()).toList(),
  };

  /// Restores source-supported map relations.
  factory WorldMap.fromJson(Map<String, dynamic> json) => WorldMap(
    id: json['id'] as String,
    locationEntityIds: List.unmodifiable(
      (json['locationEntityIds'] as List).cast<String>(),
    ),
    relationAssertionIds: List.unmodifiable(
      (json['relationAssertionIds'] as List).cast<String>(),
    ),
    evidence: _evidence(json['evidence']),
  );
}

List<AnalysisSpan> _evidence(dynamic value) {
  final spans = (value as List)
      .map(
        (item) => AnalysisSpan.fromJson((item as Map).cast<String, dynamic>()),
      )
      .toList();
  if (spans.isEmpty) throw const FormatException('Missing world evidence.');
  return List.unmodifiable(spans);
}
