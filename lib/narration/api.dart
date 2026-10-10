import 'dart:typed_data';

import '../text/narration_chunk.dart';
import '../catalog/catalog_book.dart';
import 'narration_registration.dart';

/// Private cloud boundary: no prose leaves the device before registration consent.
abstract interface class NarrationApi {
  /// Whether this build can authenticate to the narration service.
  bool get configured;

  /// Existing-session probe; startup privacy retries never prompt for sign-in.
  Future<bool> hasSession();

  /// Rollout and allowance check uses an existing identity when available.
  Future<Map<String, dynamic>> configuration();

  /// Called only after explicit per-book consent; may open Google sign-in.
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

  /// Ends the shared identity session without deleting local reading data.
  Future<void> signOut();

  /// Purges all cloud features before deleting the authenticated Firebase user.
  Future<void> deleteAccount();
}
