import 'dart:convert';

import 'analysis_entity.dart';
import 'analysis_index.dart';
import 'analysis_timeline.dart';
import 'analysis_versions.dart';
import 'analysis_world.dart';

/// Derived record shard category, matching the finalized server page contract.
enum AnalysisResultPageKind {
  /// Supported subject identities.
  entities,

  /// Exact-source resolved mention anchors.
  mentions,

  /// Evidence-backed timeline records.
  entries,

  /// Supported properties and relationships.
  assertions,

  /// Partial story-time graph nodes.
  times,

  /// Supported identity aliases.
  entity_mappings,

  /// Supported time-node equivalences.
  time_mappings,

  /// Applicable evidence-selected world facts.
  world_baselines,

  /// Supported textual location relations.
  world_maps,

  /// Per-subject temporal assertion retrieval indexes.
  subject_indexes,
}

/// Immutable result-page reference published only after complete validation.
class AnalysisResultPageDescriptor {
  /// Byte length and checksum refer to serialized immutable server page bytes.
  const AnalysisResultPageDescriptor({
    required this.pageId,
    required this.kind,
    required this.ordinal,
    required this.checksum,
    required this.byteLength,
  });

  /// Owned immutable page identifier.
  final String pageId;

  /// Derived record category.
  final AnalysisResultPageKind kind;

  /// Deterministic page order within finalization.
  final int ordinal;

  /// SHA-256 checksum of serialized page bytes.
  final String checksum;

  /// Serialized UTF-8 byte length, at most 128 KiB.
  final int byteLength;

  /// Durable immutable-page pointer.
  Map<String, dynamic> toJson() => {
    'pageId': pageId,
    'kind': kind.name,
    'ordinal': ordinal,
    'checksum': checksum,
    'byteLength': byteLength,
  };

  /// Restores a server-owned finalized reference.
  factory AnalysisResultPageDescriptor.fromJson(Map<String, dynamic> json) =>
      AnalysisResultPageDescriptor(
        pageId: json['pageId'] as String,
        kind: AnalysisResultPageKind.values.byName(json['kind'] as String),
        ordinal: json['ordinal'] as int,
        checksum: json['checksum'] as String,
        byteLength: json['byteLength'] as int,
      );
}

/// One bounded finalized derived shard; never a raw chapter-text container.
class AnalysisResultPage {
  /// Optional record arrays mirror the category-specific wire page fields.
  const AnalysisResultPage({
    this.schemaVersion = analysisSchemaVersion,
    required this.generationId,
    required this.pageId,
    required this.kind,
    required this.ordinal,
    this.entities,
    this.mentions,
    this.entries,
    this.assertions,
    this.times,
    this.entityMappings,
    this.timeMappings,
    this.worldBaselines,
    this.worldMaps,
    this.subjectIndexes,
  }) : _wireJson = null;

  AnalysisResultPage._wire(AnalysisResultPage page, this._wireJson)
    : schemaVersion = page.schemaVersion,
      generationId = page.generationId,
      pageId = page.pageId,
      kind = page.kind,
      ordinal = page.ordinal,
      entities = page.entities,
      mentions = page.mentions,
      entries = page.entries,
      assertions = page.assertions,
      times = page.times,
      entityMappings = page.entityMappings,
      timeMappings = page.timeMappings,
      worldBaselines = page.worldBaselines,
      worldMaps = page.worldMaps,
      subjectIndexes = page.subjectIndexes;

  final String? _wireJson;

  /// Compact immutable wire JSON, retaining decoded key order for checksums.
  String get serializedJson => _wireJson ?? jsonEncode(toJson());

  /// Version of persisted derived records.
  final int schemaVersion;

  /// Immutable generation ownership identity.
  final String generationId;

  /// Immutable page ownership identity.
  final String pageId;

  /// Derived record category.
  final AnalysisResultPageKind kind;

  /// Deterministic page ordinal.
  final int ordinal;

  /// Identity records, present only on their corresponding shard.
  final List<AnalysisEntity>? entities;

  /// Exact anchored mentions, present only on their corresponding shard.
  final List<AnalysisMention>? mentions;

  /// Narrative timeline records.
  final List<AnalysisEntry>? entries;

  /// Supported temporal facts.
  final List<AnalysisAssertion>? assertions;

  /// Partial-order time nodes.
  final List<AnalysisTime>? times;

  /// Supported identity reconciliation mappings.
  final List<AnalysisEntityMapping>? entityMappings;

  /// Supported time reconciliation mappings.
  final List<AnalysisTimeMapping>? timeMappings;

  /// Selected world assertions with applicability.
  final List<WorldBaseline>? worldBaselines;

  /// Supported textual location maps.
  final List<WorldMap>? worldMaps;

  /// Per-subject retrieval indexes with explicit supersession provenance.
  final List<AnalysisSubjectIndex>? subjectIndexes;

  /// Persistable wire page, keeping absent fields absent.
  Map<String, dynamic> toJson() => _wireJson != null
      ? (jsonDecode(_wireJson) as Map).cast<String, dynamic>()
      : {
          'schemaVersion': schemaVersion,
          'generationId': generationId,
          'pageId': pageId,
          'kind': kind.name,
          'ordinal': ordinal,
          if (entities != null)
            'entities': entities!.map((item) => item.toJson()).toList(),
          if (mentions != null)
            'mentions': mentions!.map((item) => item.toJson()).toList(),
          if (entries != null)
            'entries': entries!.map((item) => item.toJson()).toList(),
          if (assertions != null)
            'assertions': assertions!.map((item) => item.toJson()).toList(),
          if (times != null)
            'times': times!.map((item) => item.toJson()).toList(),
          if (entityMappings != null)
            'entityMappings': entityMappings!
                .map((item) => item.toJson())
                .toList(),
          if (timeMappings != null)
            'timeMappings': timeMappings!.map((item) => item.toJson()).toList(),
          if (worldBaselines != null)
            'worldBaselines': worldBaselines!
                .map((item) => item.toJson())
                .toList(),
          if (worldMaps != null)
            'worldMaps': worldMaps!.map((item) => item.toJson()).toList(),
          if (subjectIndexes != null)
            'subjectIndexes': subjectIndexes!
                .map((item) => item.toJson())
                .toList(),
        };

  /// Rejects unsupported/oversized pages; records are never silently truncated.
  factory AnalysisResultPage.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != analysisSchemaVersion ||
        utf8.encode(jsonEncode(json)).length > analysisPageMaxBytes) {
      throw const FormatException(
        'Unsupported or oversized analysis result page.',
      );
    }
    return AnalysisResultPage._wire(
      AnalysisResultPage(
        generationId: json['generationId'] as String,
        pageId: json['pageId'] as String,
        kind: AnalysisResultPageKind.values.byName(json['kind'] as String),
        ordinal: json['ordinal'] as int,
        entities: _records(json['entities'], AnalysisEntity.fromJson),
        mentions: _records(json['mentions'], AnalysisMention.fromJson),
        entries: _records(json['entries'], AnalysisEntry.fromJson),
        assertions: _records(json['assertions'], AnalysisAssertion.fromJson),
        times: _records(json['times'], AnalysisTime.fromJson),
        entityMappings: _records(
          json['entityMappings'],
          AnalysisEntityMapping.fromJson,
        ),
        timeMappings: _records(
          json['timeMappings'],
          AnalysisTimeMapping.fromJson,
        ),
        worldBaselines: _records(
          json['worldBaselines'],
          WorldBaseline.fromJson,
        ),
        worldMaps: _records(json['worldMaps'], WorldMap.fromJson),
        subjectIndexes: _records(
          json['subjectIndexes'],
          AnalysisSubjectIndex.fromJson,
        ),
      ),
      jsonEncode(json),
    );
  }
}

List<T>? _records<T>(dynamic value, T Function(Map<String, dynamic>) decode) =>
    value == null
    ? null
    : List.unmodifiable(
        (value as List).map(
          (item) => decode((item as Map).cast<String, dynamic>()),
        ),
      );
