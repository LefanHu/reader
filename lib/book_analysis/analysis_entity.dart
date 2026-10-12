import '../text/text_position.dart';
import 'analysis_span.dart';

/// Distinct subject categories; world is internal environmental evidence only.
enum EntityKind {
  /// An individual, never conflated solely by equal names.
  individual,

  /// A named event identity, separate from its timeline records.
  event,

  /// A collective subject with its own supported properties.
  group,

  /// A named or identifiable place.
  location,

  /// An item or artifact whose revelations remain reader-limited.
  item_artifact,

  /// Internal subject for evidence-backed environmental assertions.
  world,
}

/// The five user-facing categories, excluding the internal world subject.
enum InformationKind {
  /// Individual information.
  individual,

  /// Named-event information.
  event,

  /// Group information.
  group,

  /// Location information.
  location,

  /// Item/artifact information.
  item_artifact,
}

/// Exact-source mention and supported name roles.
enum AnalysisMentionRole {
  /// An introduced name.
  name,

  /// A separately revealed alias.
  alias,

  /// A supported title.
  title,

  /// An unambiguous reference linked to an established identity.
  resolved_reference,
}

/// Evidence-backed name; later labels cannot leak into earlier reader context.
class AnalysisName {
  /// Captures source evidence separately from the reveal anchor.
  const AnalysisName({
    required this.text,
    required this.role,
    required this.evidence,
    required this.revealAt,
  });

  /// Supported name/alias/title, not a rewritten canonical early label.
  final String text;

  /// One of name, alias or title; resolved_reference is not a name.
  final AnalysisMentionRole role;

  /// Nonempty block-local supporting evidence.
  final List<AnalysisSpan> evidence;

  /// Earliest validated source reveal of this label.
  final AnalysisPosition revealAt;

  /// Durable name record containing no chapter body.
  Map<String, dynamic> toJson() => {
    'text': text,
    'role': role.name,
    'evidence': evidence.map((span) => span.toJson()).toList(),
    'revealAt': revealAt.toJson(),
  };

  /// Restores supported labels, rejecting non-name reference roles.
  factory AnalysisName.fromJson(Map<String, dynamic> json) {
    final role = AnalysisMentionRole.values.byName(json['role'] as String);
    if (role == AnalysisMentionRole.resolved_reference) {
      throw const FormatException('Invalid analysis name role.');
    }
    final evidence = (json['evidence'] as List)
        .map(
          (item) =>
              AnalysisSpan.fromJson((item as Map).cast<String, dynamic>()),
        )
        .toList();
    if (evidence.isEmpty) throw const FormatException('Missing name evidence.');
    return AnalysisName(
      text: json['text'] as String,
      role: role,
      evidence: List.unmodifiable(evidence),
      revealAt: TextPosition.fromJson(
        (json['revealAt'] as Map).cast<String, dynamic>(),
      ),
    );
  }
}

/// Stable book-generation identity with evidence-anchored names.
class AnalysisEntity {
  /// Identity merges use explicit mappings, not rewrites of immutable shards.
  const AnalysisEntity({
    required this.id,
    required this.kind,
    required this.names,
    required this.firstIntroduction,
  });

  /// Deterministic generation-scoped identity.
  final String id;

  /// Identity category; same-kind evidence is required for reconciliation.
  final EntityKind kind;

  /// Names retain their individual reveal anchors.
  final List<AnalysisName> names;

  /// Earliest validated primary-evidence introduction.
  final AnalysisPosition firstIntroduction;

  /// Persisted identity record.
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'names': names.map((name) => name.toJson()).toList(),
    'firstIntroduction': firstIntroduction.toJson(),
  };

  /// Restores the wire identity without resolving ambiguity locally.
  factory AnalysisEntity.fromJson(Map<String, dynamic> json) => AnalysisEntity(
    id: json['id'] as String,
    kind: EntityKind.values.byName(json['kind'] as String),
    names: List.unmodifiable(
      (json['names'] as List).map(
        (item) => AnalysisName.fromJson((item as Map).cast<String, dynamic>()),
      ),
    ),
    firstIntroduction: TextPosition.fromJson(
      (json['firstIntroduction'] as Map).cast<String, dynamic>(),
    ),
  );
}

/// Exact source substring attached only to an unambiguous resolved identity.
class AnalysisMention {
  /// Evidence bounds and exact surface are validated against normalized source.
  const AnalysisMention({
    required this.id,
    required this.entityId,
    required this.span,
    required this.surface,
    required this.role,
  });

  /// Deterministic mention identity.
  final String id;

  /// Referenced entity; ambiguous references remain unresolved, not arbitrary.
  final String entityId;

  /// Exact nonempty block-local grapheme span.
  final AnalysisSpan span;

  /// Original source substring, preserving its case and Unicode spelling.
  final String surface;

  /// Distinguishes labels from resolved references.
  final AnalysisMentionRole role;

  /// Persisted mention record; surface is needed for exact future matching.
  Map<String, dynamic> toJson() => {
    'id': id,
    'entityId': entityId,
    'span': span.toJson(),
    'surface': surface,
    'role': role.name,
  };

  /// Restores exact evidence rather than snapping to a nearby paragraph.
  factory AnalysisMention.fromJson(Map<String, dynamic> json) =>
      AnalysisMention(
        id: json['id'] as String,
        entityId: json['entityId'] as String,
        span: AnalysisSpan.fromJson(
          (json['span'] as Map).cast<String, dynamic>(),
        ),
        surface: json['surface'] as String,
        role: AnalysisMentionRole.values.byName(json['role'] as String),
      );
}
