// Test state records boundary behavior; production APIs document lifecycle rules.
// ignore_for_file: public_member_api_docs
import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/text_identity/paragraph_fingerprints.dart';
import 'package:reader/text_identity/text_identity_api.dart';

/// In-memory identity: equal fingerprints resolve to the same text, standing
/// in for server alignment. The cloud book ID is the hash's first 40
/// characters, so tests can predict it.
class FakeTextIdentityApi implements TextIdentityApi {
  /// Fingerprints sent per book hash, in call order.
  final sent = <String, BookFingerprints>{};
  final calls = <String>[];

  /// When set, the next call waits for it before answering.
  Completer<void>? hold;

  /// When set, every call fails with it.
  Object? failure;

  static String textIdFor(BookFingerprints fingerprints) =>
      sha256.convert(fingerprints.fingerprints).toString().substring(0, 20);

  @override
  Future<TextIdentityResult> identify(
    CatalogBook book,
    BookFingerprints fingerprints,
  ) async {
    calls.add(book.hash);
    final pending = hold;
    hold = null;
    await pending?.future;
    if (failure case final error?) throw error;
    sent[book.hash] = fingerprints;
    return (
      cloudBookId: book.hash.substring(0, 40),
      textId: textIdFor(fingerprints),
      score: 1.0,
    );
  }
}
