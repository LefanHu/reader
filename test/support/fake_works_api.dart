// Test state records boundary behavior; production APIs document lifecycle rules.
// ignore_for_file: public_member_api_docs
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/catalog_works/work_link.dart';
import 'package:reader/catalog_works/work_text.dart';
import 'package:reader/catalog_works/works_api.dart';
import 'package:reader/identity/cloud_failure_kind.dart';
import 'package:reader/identity/cloud_service_exception.dart';

/// In-memory catalog. [index] stands in for Open Library; the first copy
/// linked to a work becomes its reference, and later copies link only with
/// identical fingerprints, standing in for server alignment.
class FakeWorksApi implements WorksApi {
  final index = <WorkSummary>[];
  final references = <String, String>{};
  final links = <String, WorkLinkResult>{};
  final calls = <String>[];
  bool degraded = false;

  /// When set, the next call waits for it before answering.
  Completer<void>? hold;

  /// When set, every call fails with it.
  Object? failure;

  /// Lowercased title and author, like the server's title-and-author identity.
  static String idFor(String title, String author) => sha256
      .convert(utf8.encode('${title.toLowerCase()}\n${author.toLowerCase()}'))
      .toString()
      .substring(0, 20);

  WorkSummary addToIndex(String title, {String author = '', int? year}) {
    final work = WorkSummary(
      id: idFor(title, author),
      title: title,
      author: author,
      firstPublishYear: year,
    );
    index.add(work);
    return work;
  }

  Future<void> _enter(String call) async {
    calls.add(call);
    final pending = hold;
    hold = null;
    await pending?.future;
    if (failure case final error?) throw error;
  }

  WorkSummary _withLinked(WorkSummary work) => WorkSummary(
    id: work.id,
    title: work.title,
    author: work.author,
    firstPublishYear: work.firstPublishYear,
    linked: references.containsKey(work.id),
  );

  @override
  Future<WorkSearch> search(String query) async {
    await _enter('search:$query');
    final words = query.toLowerCase().split(' ');
    return (
      works: [
        for (final work in index)
          if (words.any(work.title.toLowerCase().contains)) _withLinked(work),
      ],
      degraded: degraded,
    );
  }

  @override
  Future<WorkLinkResult> link(
    CatalogBook book,
    WorkText text, {
    required String title,
    required String author,
    int? firstPublishYear,
  }) async {
    await _enter('link:$title');
    final id = idFor(title, author);
    final copy = base64Encode(text.fingerprints);
    final reference = references.putIfAbsent(id, () => copy);
    if (reference != copy) {
      throw const CloudServiceException(
        CloudFailureKind.service,
        "This doesn't match the catalog's copy (0% of paragraphs match).",
        statusCode: 422,
      );
    }
    return links[book.hash] = (
      cloudBookId: book.hash.substring(0, 40),
      work: WorkSummary(
        id: id,
        title: title,
        author: author,
        firstPublishYear: firstPublishYear,
        linked: true,
      ),
      score: 1.0,
    );
  }

  @override
  Future<WorkLinkResult?> current(CatalogBook book) async {
    await _enter('current');
    return links[book.hash];
  }

  @override
  Future<void> unlink(CatalogBook book) async {
    await _enter('unlink');
    links.remove(book.hash);
  }
}
