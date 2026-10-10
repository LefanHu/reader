// Fake boundary behavior is documented at each owning type.
// ignore_for_file: public_member_api_docs
import 'dart:async';
import 'dart:typed_data';

import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/narration/api.dart';
import 'package:reader/narration/narration_registration.dart';
import 'package:reader/text/narration_chunk.dart';

import '../fixtures/narration_audio.dart';

/// Offline cloud fake records generation; a gate exposes stale-download races.
class FakeNarrationApi implements NarrationApi {
  bool offline = false;
  int registrations = 0;
  int signOuts = 0, accountDeletions = 0;
  final List<NarrationChunk> requests = [];
  final List<String> voices = [];
  final List<String> deleted = [];
  Completer<Uint8List>? gate;
  @override
  bool get configured => true;
  @override
  Future<bool> hasSession() async => true;
  @override
  Future<Map<String, dynamic>> configuration() async => {
    'enabled': true,
    'remaining': 500000,
  };
  @override
  Future<NarrationRegistration> register(CatalogBook book) async {
    registrations++;
    return const NarrationRegistration('account', 'cloud-book', 500000);
  }

  @override
  Future<Uint8List> audio(
    String bookId,
    NarrationChunk chunk,
    String voice, {
    required bool Function() isCurrent,
  }) async {
    if (offline) throw StateError('Offline');
    requests.add(chunk);
    voices.add(voice);
    return gate == null ? testWav() : gate!.future;
  }

  @override
  Future<void> deleteBook(String bookId) async {
    if (offline) throw StateError('Offline');
    deleted.add(bookId);
  }

  @override
  Future<void> signOut() async {
    signOuts++;
  }

  @override
  Future<void> deleteAccount() async {
    if (offline) throw StateError('Offline');
    accountDeletions++;
  }
}
