import 'dart:io';

import '../atomic_json_file.dart';
import '../catalog/catalog_book.dart';
import '../generation_fence.dart';
import '../text/document_store.dart';
import 'work_link.dart';
import 'work_text.dart';
import 'works_api.dart';

/// Owns each book's link to the global catalog of works.
///
/// Linking is always an explicit user action, never background work. Links are
/// kept per account in one [AtomicJsonFile]; a link made under another account
/// is invisible until the server confirms it again. Account changes and book
/// deletion retire in-flight actions through [GenerationFence]s, so a late
/// response never records a link for the wrong account or a deleted book.
class WorkLinkCoordinator {
  /// Persists to `work-links.json` under [root]; [documents] is for tests.
  WorkLinkCoordinator({
    required this.api,
    required Directory root,
    required this.account,
    required this.changed,
    this.documents,
  }) : _file = AtomicJsonFile(File('${root.path}/work-links.json'));

  /// Catalog transport; every call may prompt sign-in.
  final WorksApi api;

  /// Email of the signed-in account, or null when signed out.
  final String? Function() account;

  /// Notifies the owner that a link changed.
  final void Function() changed;

  /// Normalized text boundary; null reads on a background isolate.
  final TextDocumentStore? documents;

  final AtomicJsonFile _file;
  final _links = <String, WorkLink>{};
  final _accountFence = GenerationFence();
  final _bookFences = KeyedGenerationFence<String>();

  /// Loads persisted links; a malformed record drops only itself.
  Future<void> restore() async {
    final stored = await _file.read(
      (json) => json['links'] is List
          ? decodeRecords(json['links'] as List, WorkLink.fromJson)
          : null,
    );
    for (final link in stored?.value ?? const <WorkLink>[]) {
      _links[link.bookHash] = link;
    }
  }

  /// [book]'s link for the signed-in account, if one is known locally.
  WorkLink? linkFor(CatalogBook book) {
    final link = _links[book.hash];
    final email = account();
    return link != null && email != null && link.account == email ? link : null;
  }

  /// Server book ID of any recorded link, so deletion can purge it.
  String? cloudBookIdFor(CatalogBook book) => _links[book.hash]?.cloudBookId;

  /// Works matching [query]; an empty query returns none without a request.
  Future<WorkSearch> search(String query) => query.trim().isEmpty
      ? Future.value((works: const <WorkSummary>[], degraded: false))
      : api.search(query);

  /// Asks the server for [book]'s link, replacing what is recorded locally.
  Future<WorkLink?> refresh(CatalogBook book) =>
      _act(book, (_) => api.current(book));

  /// Links [book] to the work titled [title] by [author]; fails with HTTP 422
  /// when the work's reference text does not align with this copy.
  Future<WorkLink?> link(
    CatalogBook book, {
    required String title,
    required String author,
    int? firstPublishYear,
  }) => _act(book, (ticket) async {
    final text = await buildWorkText(book.path, documents: documents);
    return ticket.isCurrent
        ? api.link(
            book,
            text,
            title: title,
            author: author,
            firstPublishYear: firstPublishYear,
          )
        : null;
  });

  /// Removes [book]'s link on the server and locally.
  Future<void> unlink(CatalogBook book) => _act(book, (_) async {
    await api.unlink(book);
    return null;
  });

  /// Retires in-flight actions before an account change.
  void invalidateAccount() => _accountFence.invalidate();

  /// Retires [book]'s in-flight actions and drops its record on deletion.
  Future<void> forget(CatalogBook book) async {
    _bookFences.invalidate(book.hash);
    if (_links.remove(book.hash) != null) await _persist();
  }

  /// Drops every record after the cloud account itself was deleted.
  Future<void> clearAccountData() async {
    _accountFence.invalidate();
    _links.clear();
    await _persist();
  }

  /// Runs one server action for [book] and records its resulting link (null
  /// means unlinked), unless the account or book moved on meanwhile.
  Future<WorkLink?> _act(
    CatalogBook book,
    Future<WorkLinkResult?> Function(_Ticket ticket) action,
  ) async {
    final ticket = _Ticket(
      _accountFence.capture(),
      _bookFences.capture(book.hash),
    );
    final result = await action(ticket);
    final email = account();
    if (!ticket.isCurrent || email == null) return null;
    WorkLink? link;
    if (result == null) {
      _links.remove(book.hash);
    } else {
      link = _links[book.hash] = WorkLink(
        bookHash: book.hash,
        account: email,
        cloudBookId: result.cloudBookId,
        work: result.work,
        score: result.score,
      );
    }
    await _persist(ticket);
    changed();
    return link;
  }

  Future<void> _persist([_Ticket? ticket]) {
    final links = [for (final link in _links.values) link.toJson()];
    return _file.update(
      () async => {'links': links},
      isCurrent: ticket == null ? null : () => ticket.isCurrent,
    );
  }
}

/// Account and book tickets captured together when an action starts.
class _Ticket {
  _Ticket(this._account, this._book);

  final FenceTicket _account;
  final FenceTicket _book;

  bool get isCurrent => _account.isCurrent && _book.isCurrent;
}
