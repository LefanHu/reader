import 'analysis_protocol.dart';
import 'analysis_result.dart';
import 'analysis_source_models.dart';

/// Reference to an immutable uploaded descriptor page.
class AnalysisDescriptorPageReference {
  /// Checksum and length cover the original serialized page bytes.
  const AnalysisDescriptorPageReference({
    required this.ordinal,
    required this.checksum,
    required this.byteLength,
  });

  /// Zero-based manifest page order.
  final int ordinal;

  /// SHA-256 checksum of serialized page bytes.
  final String checksum;

  /// Serialized UTF-8 length, bounded at 128 KiB.
  final int byteLength;

  /// Durable descriptor-page reference without prose.
  Map<String, dynamic> toJson() => {
    'ordinal': ordinal,
    'checksum': checksum,
    'byteLength': byteLength,
  };

  /// Restores an immutable descriptor-page pointer.
  factory AnalysisDescriptorPageReference.fromJson(Map<String, dynamic> json) =>
      AnalysisDescriptorPageReference(
        ordinal: json['ordinal'] as int,
        checksum: json['checksum'] as String,
        byteLength: json['byteLength'] as int,
      );
}

/// Complete server-owned analysis manifest with coverage and immutable shards.
/// Public status routes expose accountKey, not this server-derived UID field.
class AnalysisManifest {
  /// Source contains only descriptors, never finalized raw chapter prose.
  const AnalysisManifest({
    required this.source,
    required this.uid,
    required this.bookId,
    required this.generationId,
    required this.status,
    required this.descriptorPages,
    required this.entityMappingPages,
    required this.timeMappingPages,
    required this.resultPages,
    required this.finalizedRevision,
  });

  /// Full deterministic prose-free generation source identity.
  final AnalysisSourceManifest source;

  /// Server-derived account owner; never supplied as request ownership.
  final String uid;

  /// Shared account-salted cloud book identity.
  final String bookId;

  /// Immutable generation identity.
  final String generationId;

  /// Durable server generation status.
  final AnalysisGenerationStatus status;

  /// Validated ordered descriptor page checksums.
  final List<AnalysisDescriptorPageReference> descriptorPages;

  /// Immutable supported entity mapping shards.
  final List<AnalysisResultPageDescriptor> entityMappingPages;

  /// Immutable supported time mapping shards.
  final List<AnalysisResultPageDescriptor> timeMappingPages;

  /// Finalized result shard pointers and checksums.
  final List<AnalysisResultPageDescriptor> resultPages;

  /// Complete atomically published revision; null before publication.
  final String? finalizedRevision;

  /// Mirrors the flattened backend persisted manifest, without raw text.
  Map<String, dynamic> toJson() => {
    ...source.toJson(),
    'uid': uid,
    'bookId': bookId,
    'generationId': generationId,
    'status': status.name,
    'descriptorPages': descriptorPages.map((page) => page.toJson()).toList(),
    'entityMappingPages': entityMappingPages
        .map((page) => page.toJson())
        .toList(),
    'timeMappingPages': timeMappingPages.map((page) => page.toJson()).toList(),
    'resultPages': resultPages.map((page) => page.toJson()).toList(),
    'finalizedRevision': finalizedRevision,
  };

  /// Restores a complete manifest; corrupt persisted fields reject the record.
  factory AnalysisManifest.fromJson(Map<String, dynamic> json) =>
      AnalysisManifest(
        source: AnalysisSourceManifest.fromJson(json),
        uid: json['uid'] as String,
        bookId: json['bookId'] as String,
        generationId: json['generationId'] as String,
        status: AnalysisGenerationStatus.values.byName(
          json['status'] as String,
        ),
        descriptorPages: List.unmodifiable(
          (json['descriptorPages'] as List).map(
            (item) => AnalysisDescriptorPageReference.fromJson(
              (item as Map).cast<String, dynamic>(),
            ),
          ),
        ),
        entityMappingPages: _pages(json['entityMappingPages']),
        timeMappingPages: _pages(json['timeMappingPages']),
        resultPages: _pages(json['resultPages']),
        finalizedRevision: json['finalizedRevision'] as String?,
      );
}

List<AnalysisResultPageDescriptor> _pages(dynamic value) => List.unmodifiable(
  (value as List).map(
    (item) => AnalysisResultPageDescriptor.fromJson(
      (item as Map).cast<String, dynamic>(),
    ),
  ),
);
