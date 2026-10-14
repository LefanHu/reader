import 'dart:async';
import 'dart:io';

import '../atomic_json_file.dart';
import '../catalog/catalog_book.dart';
import '../generation_fence.dart';
import '../identity/cloud_identity_exception.dart';
import '../identity/cloud_service_exception.dart';
import '../text/document_store.dart';
import 'paragraph_fingerprints.dart';
import 'text_identity.dart';
import 'text_identity_api.dart';

/// Identifies every book as a shared text in the background, by content.
///
/// [nudge] runs one drain at a time over the catalog: each book without an
/// identity for the signed-in account is fingerprinted off the UI isolate and
/// identified, one request at a time. A cloud failure (no session, offline,
/// server error) ends the drain quietly; the next nudge retries. Identities are
/// kept per account in one [AtomicJsonFile]. Account changes and book deletion
/// retire in-flight work through [GenerationFence]s, so a late response never
/// records an identity for the wrong account or a deleted book.
class TextIdentityCoordinator {
  /// Persists to `text-identities.json` under [root]; [documents] is for tests.
  TextIdentityCoordinator({
    required this.api,
    required Directory root,
    required this.account,
    required this.books,
    required this.changed,
    this.documents,
  }) : _file = AtomicJsonFile(File('${root.path}/text-identities.json'));

  /// Noninteractive transport; calls never prompt sign-in.
  final TextIdentityApi api;

  /// Email of the signed-in account, or null when signed out.
  final String? Function() account;

  /// The live catalog, read at every drain step.
  final List<CatalogBook> Function() books;

  /// Notifies the owner that an identity changed.
  final void Function() changed;

  /// Normalized text boundary; null reads on a background isolate.
  final TextDocumentStore? documents;

  final AtomicJsonFile _file;
  final _identities = <String, TextIdentity>{};
  final _accountFence = GenerationFence();
  final _bookFences = KeyedGenerationFence<String>();
  Future<void>? _running;
  bool _again = false;
  bool _disposed = false;

  /// Completes when no drain is running; for tests and orderly shutdown.
  Future<void> get idle async {
    for (var running = _running; running != null; running = _running) {
      await running;
    }
  }

  /// Loads persisted identities; a malformed record drops only itself.
  Future<void> restore() async {
    final stored = await _file.read(
      (json) => json['identities'] is List
          ? decodeRecords(json['identities'] as List, TextIdentity.fromJson)
          : null,
    );
    for (final identity in stored?.value ?? const <TextIdentity>[]) {
      _identities[identity.bookHash] = identity;
    }
  }

  /// [book]'s identity for the signed-in account, if known.
  TextIdentity? identityFor(CatalogBook book) {
    final identity = _identities[book.hash];
    final email = account();
    return identity != null && email != null && identity.account == email
        ? identity
        : null;
  }

  /// Server book ID of any recorded identity, so deletion can purge it.
  String? cloudBookIdFor(CatalogBook book) =>
      _identities[book.hash]?.cloudBookId;

  /// Starts a drain, or schedules one more after the running drain.
  void nudge() {
    if (_disposed) return;
    if (_running != null) {
      _again = true;
      return;
    }
    _running = _drain().whenComplete(() {
      _running = null;
      if (_again) {
        _again = false;
        nudge();
      }
    });
  }

  /// Retires in-flight work before an account change.
  void invalidateAccount() => _accountFence.invalidate();

  /// Retires [book]'s in-flight work and drops its record on deletion.
  Future<void> forget(CatalogBook book) async {
    _bookFences.invalidate(book.hash);
    if (_identities.remove(book.hash) != null) await _persist();
  }

  /// Drops every record after the cloud account itself was deleted.
  Future<void> clearAccountData() async {
    _accountFence.invalidate();
    _identities.clear();
    await _persist();
  }

  /// Stops scheduling and retires in-flight work.
  void dispose() {
    _disposed = true;
    _accountFence.invalidate();
  }

  Future<void> _drain() async {
    final attempted = <String>{};
    while (!_disposed) {
      final email = account();
      if (email == null) return;
      CatalogBook? next;
      for (final book in books()) {
        if (identityFor(book) == null && attempted.add(book.hash)) {
          next = book;
          break;
        }
      }
      if (next == null) return;
      try {
        await _identify(next, email);
      } on CloudIdentityException {
        return;
      } on CloudServiceException {
        return;
      } on Object {
        // A book whose normalized text cannot be read only skips itself.
      }
    }
  }

  Future<void> _identify(CatalogBook book, String email) async {
    final accountTicket = _accountFence.capture();
    final bookTicket = _bookFences.capture(book.hash);
    bool current() =>
        accountTicket.isCurrent && bookTicket.isCurrent && account() == email;
    final fingerprints = await buildBookFingerprints(
      book.path,
      documents: documents,
    );
    if (!current()) return;
    final result = await api.identify(book, fingerprints);
    if (!current()) return;
    _identities[book.hash] = TextIdentity(
      bookHash: book.hash,
      account: email,
      cloudBookId: result.cloudBookId,
      textId: result.textId,
      score: result.score,
    );
    await _persist(current);
    if (current()) changed();
  }

  Future<void> _persist([bool Function()? isCurrent]) {
    final identities = [
      for (final identity in _identities.values) identity.toJson(),
    ];
    return _file.update(
      () async => {'identities': identities},
      isCurrent: isCurrent,
    );
  }
}
