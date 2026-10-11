import 'dart:typed_data';

import '../text/narration_chunk.dart';
import '../catalog/catalog_book.dart';
import 'narration_registration.dart';

/// Private cloud boundary: registration and generation require Auth/App Check.
abstract interface class NarrationApi {
  /// Whether this build can authenticate to the narration service.
  bool get configured;

  /// Rollout and allowance check uses an existing identity when available.
  Future<Map<String, dynamic>> configuration();

  /// Registers an account-scoped fingerprint; may open Google sign-in.
  Future<NarrationRegistration> register(CatalogBook book);

  /// Idempotent generation/download of one exact chunk, bounded by the caller.
  Future<Uint8List> audio(
    String bookId,
    NarrationChunk chunk,
    String voice, {
    required bool Function() isCurrent,
  });

  /// Durable privacy retry succeeds for an already-deleted registration.
  Future<void> deleteBook(String bookId);
}
