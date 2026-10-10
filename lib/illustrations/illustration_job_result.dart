// DTO fields mirror the documented REST contract in this file.
// ignore_for_file: public_member_api_docs

import 'illustration_scene.dart';

/// Current server state for an idempotent chapter generation job.
class IllustrationJobResult {
  const IllustrationJobResult({
    required this.id,
    required this.status,
    required this.scenes,
    this.failureCategory,
  });

  final String id;
  final String status;
  final List<IllustrationScene> scenes;
  final String? failureCategory;
}
