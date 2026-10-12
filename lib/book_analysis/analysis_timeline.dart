import '../text/text_position.dart';
import 'analysis_entity.dart';
import 'analysis_span.dart';

/// Why an evidence-backed timeline record matters to the narrative.
enum AnalysisEntryKind {
  /// First introduction of one or more subjects.
  introduction,

  /// Description need not claim a physical change.
  description,

  /// An occurrence, separate from any named-event identity.
  event,

  /// Explicit meaningful state change with supersession provenance.
  change,

  /// Newly disclosed information, not necessarily a transformation.
  revelation,
}

/// Supported extent of applicability, never guessed from reveal order.
enum AnalysisAssertionScope {
  /// Persists until explicitly superseded.
  enduring,

  /// Ends at a supported scene boundary.
  scene,

  /// Applies between established endpoints.
  interval,

  /// Applicability cannot safely be determined.
  unknown,
}

/// Literary support strength; uncertain claims must not become hidden defaults.
enum AnalysisAssertionSupport {
  /// Directly asserted source fact.
  asserted,

  /// A report that is not automatically literary truth.
  reported,

  /// Explicitly unresolved support.
  uncertain,
}

/// Environmental categories eligible for carefully filtered world context.
enum AnalysisWorldCategory {
  /// Supported terrain and location relations.
  geography,

  /// Supported built environment.
  architecture,

  /// Supported climate.
  climate,

  /// Supported ambient conditions.
  ambient_environment,

  /// Supported world rules, never hidden identity/property shortcuts.
  world_rule,
}

/// A bounded paraphrase of supported narrative information with separate time.
class AnalysisEntry {
  /// One record can describe multiple subjects and user-facing categories.
  const AnalysisEntry({
    required this.id,
    required this.entryKind,
    required this.subjectIds,
    required this.informationKinds,
    required this.summary,
    required this.evidence,
    required this.revealAt,
    required this.timeId,
    required this.assertionIds,
    required this.supersedesAssertionIds,
  });

  /// Deterministic timeline record identity.
  final String id;

  /// Introduction/description/event/change/revelation classification.
  final AnalysisEntryKind entryKind;

  /// All supported subjects involved in the record.
  final List<String> subjectIds;

  /// User-facing categories only; internal world is not a visible category.
  final List<InformationKind> informationKinds;

  /// Bounded paraphrased summary, never a chapter quotation.
  final String summary;

  /// Nonempty, potentially cross-block array of local evidence spans.
  final List<AnalysisSpan> evidence;

  /// Earliest validated evidence reveal anchor.
  final AnalysisPosition revealAt;

  /// Associated partial-order story-time node; null means unresolved time.
  final String? timeId;

  /// Facts established or described by the record.
  final List<String> assertionIds;

  /// Explicitly superseded facts, preserving their provenance.
  final List<String> supersedesAssertionIds;

  /// Prose-free temporal record.
  Map<String, dynamic> toJson() => {
    'id': id,
    'entryKind': entryKind.name,
    'subjectIds': subjectIds,
    'informationKinds': informationKinds.map((kind) => kind.name).toList(),
    'summary': summary,
    'evidence': evidence.map((span) => span.toJson()).toList(),
    'revealAt': revealAt.toJson(),
    'timeId': timeId,
    'assertionIds': assertionIds,
    'supersedesAssertionIds': supersedesAssertionIds,
  };

  /// Restores classification and exact anchors without inferring chronology.
  factory AnalysisEntry.fromJson(Map<String, dynamic> json) {
    final kinds = (json['informationKinds'] as List)
        .map((kind) => InformationKind.values.byName(kind as String))
        .toList();
    return AnalysisEntry(
      id: json['id'] as String,
      entryKind: AnalysisEntryKind.values.byName(json['entryKind'] as String),
      subjectIds: List.unmodifiable(
        (json['subjectIds'] as List).cast<String>(),
      ),
      informationKinds: List.unmodifiable(kinds),
      summary: json['summary'] as String,
      evidence: _evidence(json['evidence']),
      revealAt: TextPosition.fromJson(
        (json['revealAt'] as Map).cast<String, dynamic>(),
      ),
      timeId: json['timeId'] as String?,
      assertionIds: List.unmodifiable(
        (json['assertionIds'] as List).cast<String>(),
      ),
      supersedesAssertionIds: List.unmodifiable(
        (json['supersedesAssertionIds'] as List).cast<String>(),
      ),
    );
  }
}

/// A supported fact separating reader reveal from temporal applicability.
class AnalysisAssertion {
  /// Null endpoints mean unknown, never implicit beginning or end of book.
  const AnalysisAssertion({
    required this.id,
    required this.subjectId,
    required this.property,
    required this.value,
    this.objectEntityId,
    required this.evidence,
    required this.revealAt,
    required this.validFromTimeId,
    required this.validUntilTimeId,
    required this.scope,
    required this.support,
    required this.worldCategory,
    required this.retroactiveWorld,
  });

  /// Deterministic fact identity.
  final String id;

  /// Supported subject, not an inferred group member.
  final String subjectId;

  /// Bounded normalized open-ended property, not a fixed property catalogue.
  final String property;

  /// Bounded supported value.
  final String value;

  /// Optional relationship target.
  final String? objectEntityId;

  /// Nonempty local evidence spans establishing the assertion.
  final List<AnalysisSpan> evidence;

  /// When the reader learns this fact, not necessarily when it began.
  final AnalysisPosition revealAt;

  /// Established applicability start; null means unknown.
  final String? validFromTimeId;

  /// Established applicability end; null does not mean forever.
  final String? validUntilTimeId;

  /// Supported applicability extent.
  final AnalysisAssertionScope scope;

  /// Asserted, reported or uncertain source support.
  final AnalysisAssertionSupport support;

  /// Environmental category, absent for ordinary subject properties.
  final AnalysisWorldCategory? worldCategory;

  /// Supported old-world revelation, never permission to reveal hidden people.
  final bool retroactiveWorld;

  /// Durable assertion preserves uncertainty and optional relationships.
  Map<String, dynamic> toJson() => {
    'id': id,
    'subjectId': subjectId,
    'property': property,
    'value': value,
    if (objectEntityId != null) 'objectEntityId': objectEntityId,
    'evidence': evidence.map((span) => span.toJson()).toList(),
    'revealAt': revealAt.toJson(),
    'validFromTimeId': validFromTimeId,
    'validUntilTimeId': validUntilTimeId,
    'scope': scope.name,
    'support': support.name,
    'worldCategory': worldCategory?.name,
    'retroactiveWorld': retroactiveWorld,
  };

  /// Restores facts without choosing a latest-wins literary truth.
  factory AnalysisAssertion.fromJson(
    Map<String, dynamic> json,
  ) => AnalysisAssertion(
    id: json['id'] as String,
    subjectId: json['subjectId'] as String,
    property: json['property'] as String,
    value: json['value'] as String,
    objectEntityId: json['objectEntityId'] as String?,
    evidence: _evidence(json['evidence']),
    revealAt: TextPosition.fromJson(
      (json['revealAt'] as Map).cast<String, dynamic>(),
    ),
    validFromTimeId: json['validFromTimeId'] as String?,
    validUntilTimeId: json['validUntilTimeId'] as String?,
    scope: AnalysisAssertionScope.values.byName(json['scope'] as String),
    support: AnalysisAssertionSupport.values.byName(json['support'] as String),
    worldCategory: json['worldCategory'] == null
        ? null
        : AnalysisWorldCategory.values.byName(json['worldCategory'] as String),
    retroactiveWorld: json['retroactiveWorld'] as bool,
  );
}

/// Partial-order story-time node; incomparable nodes are not linearly sorted.
class AnalysisTime {
  /// Cycles and unsupported temporal links are rejected during finalization.
  const AnalysisTime({
    required this.id,
    this.label,
    required this.beforeIds,
    required this.afterIds,
    required this.evidence,
  });

  /// Deterministic story-time identity.
  final String id;

  /// Optional explicit source date/label, never a fabricated calendar date.
  final String? label;

  /// Supported nodes after this node.
  final List<String> beforeIds;

  /// Supported nodes before this node.
  final List<String> afterIds;

  /// Nonempty evidence supporting the node and its temporal relations.
  final List<AnalysisSpan> evidence;

  /// Persisted graph node, independent of narrative source order.
  Map<String, dynamic> toJson() => {
    'id': id,
    if (label != null) 'label': label,
    'beforeIds': beforeIds,
    'afterIds': afterIds,
    'evidence': evidence.map((span) => span.toJson()).toList(),
  };

  /// Restores a node without manufacturing relations to incomparable times.
  factory AnalysisTime.fromJson(Map<String, dynamic> json) => AnalysisTime(
    id: json['id'] as String,
    label: json['label'] as String?,
    beforeIds: List.unmodifiable((json['beforeIds'] as List).cast<String>()),
    afterIds: List.unmodifiable((json['afterIds'] as List).cast<String>()),
    evidence: _evidence(json['evidence']),
  );
}

List<AnalysisSpan> _evidence(dynamic value) {
  final spans = (value as List)
      .map(
        (item) => AnalysisSpan.fromJson((item as Map).cast<String, dynamic>()),
      )
      .toList();
  if (spans.isEmpty) throw const FormatException('Missing analysis evidence.');
  return List.unmodifiable(spans);
}
