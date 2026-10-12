import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../text/document_store.dart';
import '../text/grapheme_boundary.dart';
import '../text/text_section.dart';
import 'analysis_entity.dart';
import 'analysis_result.dart';
import 'analysis_source.dart';
import 'analysis_source_models.dart';
import 'analysis_versions.dart';

/// Checks immutable bytes and exact normalized anchors, never snapping ranges.
class AnalysisValidator {
  AnalysisValidator({
    required this.documents,
    required this.sourcePath,
    required this.manifest,
    required this.isCurrent,
  });

  final TextDocumentStore documents;
  final String sourcePath;
  final AnalysisSourceManifest manifest;
  final bool Function() isCurrent;
  final Map<String, Set<String>> _ids = {};
  final List<(String, String)> _references = [];
  final Map<String, Set<String>> _timeEdges = {};

  Future<void> validate(
    AnalysisResultPage page,
    AnalysisResultPageDescriptor descriptor,
    String generationId,
  ) async {
    final bytes = utf8.encode(page.serializedJson);
    if (page.schemaVersion != analysisSchemaVersion ||
        page.generationId != generationId ||
        page.pageId != descriptor.pageId ||
        page.kind != descriptor.kind ||
        page.ordinal != descriptor.ordinal ||
        bytes.length > analysisPageMaxBytes ||
        bytes.length != descriptor.byteLength ||
        sha256.convert(bytes).toString() != descriptor.checksum) {
      throw const FormatException(
        'Invalid analysis page identity or checksum.',
      );
    }
    final json = page.toJson();
    final positions = <Map<String, dynamic>>[];
    final spans = <Map<String, dynamic>>[];
    final sectionOrdinals = {
      for (final section in manifest.sections) section.id: section.ordinal,
    };
    final blockOrdinals = <String, int>{
      for (final chunk in manifest.chunks)
        for (final span in chunk.primary)
          '${span.sectionId}\u0000${span.blockId}': span.blockOrdinal,
    };
    int comparePositions(Map a, Map b) {
      final section = (sectionOrdinals[a['sectionId']] ?? -1).compareTo(
        sectionOrdinals[b['sectionId']] ?? -1,
      );
      if (section != 0) return section;
      final block =
          (blockOrdinals['${a['sectionId']}\u0000${a['blockId']}'] ?? -1)
              .compareTo(
                blockOrdinals['${b['sectionId']}\u0000${b['blockId']}'] ?? -1,
              );
      return block != 0
          ? block
          : (a['offset'] as int).compareTo(b['offset'] as int);
    }

    void collect(Object? value) {
      if (value is Map) {
        final map = value.cast<String, dynamic>();
        if (map.containsKey('version') &&
            map.containsKey('sectionId') &&
            map.containsKey('blockId') &&
            map.containsKey('offset')) {
          positions.add(map);
        } else {
          final evidence = map['evidence'];
          final reveal = map['revealAt'];
          if (reveal is Map && evidence is List) {
            if (evidence.isEmpty)
              throw const FormatException('Missing analysis reveal evidence.');
            final ends =
                evidence.map((span) => (span as Map)['end'] as Map).toList()
                  ..sort(comparePositions);
            final mapping = map.containsKey('canonicalEntityId');
            final supportedMappingAnchor =
                mapping &&
                evidence.any(
                  (span) =>
                      comparePositions(reveal, (span as Map)['start'] as Map) ==
                          0 ||
                      comparePositions(reveal, span['end'] as Map) == 0,
                );
            if (!supportedMappingAnchor &&
                comparePositions(reveal, ends.last) != 0) {
              throw const FormatException(
                'Analysis reveal is unrelated to evidence.',
              );
            }
          }
          if (map['start'] is Map && map['end'] is Map) spans.add(map);
          for (final item in map.values) {
            collect(item);
          }
        }
      } else if (value is List) {
        for (final item in value) {
          collect(item);
        }
      }
    }

    collect(json);
    positions.sort(
      (a, b) => (sectionOrdinals[a['sectionId']] ?? -1).compareTo(
        sectionOrdinals[b['sectionId']] ?? -1,
      ),
    );
    TextSection? section;
    final boundaries = <String, GraphemeBoundaries>{};
    final sourceText = <String, String>{};
    final checkedBlocks = <String>{};
    for (final position in positions) {
      if (!isCurrent()) return;
      final id = position['sectionId'];
      final ordinal = sectionOrdinals[id];
      if (position['version'] != manifest.documentVersion || ordinal == null) {
        throw const FormatException('Invalid analysis evidence section.');
      }
      if (section?.id != id) {
        section = await documents.loadSection(sourcePath, id as String);
        if (!isCurrent()) return;
        boundaries.clear();
        if (section.id != id ||
            section.blocks.length != manifest.sections[ordinal].blockCount) {
          throw const FormatException('Analysis evidence source changed.');
        }
      }
      final blockId = position['blockId'];
      final blockOrdinal = section!.blocks.indexWhere(
        (block) => block.id == blockId,
      );
      if (blockOrdinal < 0)
        throw const FormatException('Invalid analysis evidence block.');
      final block = section.blocks[blockOrdinal];
      final offset = position['offset'];
      if (offset is! int ||
          offset < 0 ||
          offset > block.text.length ||
          !(boundaries[block.id] ??= GraphemeBoundaries(
            block.text,
          )).contains(offset)) {
        throw const FormatException('Invalid analysis evidence grapheme.');
      }
      final key = '$id\u0000$blockId';
      if (checkedBlocks.add(key)) {
        for (final chunk in manifest.chunks) {
          for (final span in chunk.primary) {
            if (span.sectionId != id || span.blockId != blockId) continue;
            if (span.blockOrdinal != blockOrdinal ||
                span.blockLength != block.text.length ||
                span.startOffset < 0 ||
                span.endOffset > block.text.length ||
                analysisSpanHash(
                      version: span.version,
                      sectionOrdinal: ordinal,
                      sectionId: id as String,
                      blockOrdinal: blockOrdinal,
                      blockId: block.id,
                      startOffset: span.startOffset,
                      endOffset: span.endOffset,
                      text: block.text.substring(
                        span.startOffset,
                        span.endOffset,
                      ),
                    ) !=
                    span.hash) {
              throw const FormatException(
                'Analysis evidence source hash changed.',
              );
            }
          }
        }
      }
      // Retain only exact mention substrings, not whole loaded blocks.
      for (final mention in page.mentions ?? const []) {
        if (mention.span.start.sectionId == id &&
            mention.span.start.blockId == blockId) {
          if (mention.span.end.offset > block.text.length ||
              block.text.substring(
                    mention.span.start.offset,
                    mention.span.end.offset,
                  ) !=
                  mention.surface) {
            throw const FormatException(
              'Analysis mention surface differs from source.',
            );
          }
          sourceText[mention.id] = mention.surface;
        }
      }
    }
    for (final span in spans) {
      final start = (span['start'] as Map).cast<String, dynamic>();
      final end = (span['end'] as Map).cast<String, dynamic>();
      if (start['version'] != end['version'] ||
          start['sectionId'] != end['sectionId'] ||
          start['blockId'] != end['blockId'] ||
          (end['offset'] as int) <= (start['offset'] as int)) {
        throw const FormatException('Invalid analysis evidence range.');
      }
    }
    for (final entity in page.entities ?? const []) {
      // A later window may add evidence-anchored names to an established ID;
      // the kind can never change, and every other record kind stays unique.
      final known = _entityKinds[entity.id];
      if (known == null) {
        _add('entity', entity.id);
        _entityKinds[entity.id] = entity.kind;
      } else if (known != entity.kind) {
        throw const FormatException('Entity kind changed.');
      }
    }
    for (final mention in page.mentions ?? const []) {
      _add('mention', mention.id);
      _references.add(('entity', mention.entityId));
      if (!sourceText.containsKey(mention.id))
        throw const FormatException('Missing mention source.');
    }
    for (final entry in page.entries ?? const []) {
      _add('entry', entry.id);
      for (final id in entry.subjectIds) {
        _references.add(('entity', id));
      }
      for (final id in [
        ...entry.assertionIds,
        ...entry.supersedesAssertionIds,
      ]) {
        _references.add(('assertion', id));
      }
      if (entry.timeId != null) _references.add(('time', entry.timeId!));
    }
    for (final assertion in page.assertions ?? const []) {
      _add('assertion', assertion.id);
      _references.add(('entity', assertion.subjectId));
      if (assertion.objectEntityId != null)
        _references.add(('entity', assertion.objectEntityId!));
      for (final id in [
        assertion.validFromTimeId,
        assertion.validUntilTimeId,
      ]) {
        if (id != null) _references.add(('time', id));
      }
    }
    for (final time in page.times ?? const []) {
      _add('time', time.id);
      for (final id in time.beforeIds) {
        _references.add(('time', id));
        (_timeEdges[time.id] ??= {}).add(id);
      }
      for (final id in time.afterIds) {
        _references.add(('time', id));
        (_timeEdges[id] ??= {}).add(time.id);
      }
    }
    for (final mapping in page.entityMappings ?? const []) {
      _references.add(('entity', mapping.canonicalEntityId));
    }
    for (final mapping in page.timeMappings ?? const []) {
      _references.add(('time', mapping.canonicalTimeId));
    }
    for (final baseline in page.worldBaselines ?? const []) {
      for (final id in baseline.assertionIds) {
        _references.add(('assertion', id));
      }
      for (final id in [baseline.validFromTimeId, baseline.validUntilTimeId]) {
        if (id != null) _references.add(('time', id));
      }
    }
    for (final map in page.worldMaps ?? const []) {
      for (final id in map.locationEntityIds) {
        _references.add(('entity', id));
      }
      for (final id in map.relationAssertionIds) {
        _references.add(('assertion', id));
      }
    }
    for (final index in page.subjectIndexes ?? const []) {
      _references.add(('entity', index.subjectId));
      for (final id in index.assertionIds) {
        _references.add(('assertion', id));
      }
      for (final id in index.entryIds) {
        _references.add(('entry', id));
      }
      for (final supersession in index.supersessions) {
        _references.add(('assertion', supersession.assertionId));
        _references.add(('entry', supersession.entryId));
        for (final id in supersession.supersedesAssertionIds) {
          _references.add(('assertion', id));
        }
      }
    }
  }

  final Map<String, EntityKind> _entityKinds = {};

  void _add(String kind, String id) {
    if (id.isEmpty || !(_ids[kind] ??= {}).add(id)) {
      throw const FormatException('Duplicate analysis record identity.');
    }
  }

  void finish() {
    for (final (kind, id) in _references) {
      if (!(_ids[kind]?.contains(id) ?? false)) {
        throw const FormatException('Missing analysis record reference.');
      }
    }
    final visited = <String>{};
    final active = <String>{};
    void visit(String id) {
      if (active.contains(id))
        throw const FormatException('Cyclic analysis time graph.');
      if (!visited.add(id)) return;
      active.add(id);
      for (final next in _timeEdges[id] ?? const <String>{}) {
        visit(next);
      }
      active.remove(id);
    }

    for (final id in _ids['time'] ?? const <String>{}) {
      visit(id);
    }
  }
}
