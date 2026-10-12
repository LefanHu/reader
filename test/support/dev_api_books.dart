import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/catalog/catalog_book.dart';
import 'package:reader/illustrations/http_illustration_api.dart';
import 'package:reader/text/text_position.dart';

import '../fixtures/catalog_book.dart';

/// [testBook] with a unique content hash: cloud book IDs derive from the uid
/// and hash, so parallel tests on one shared uid must never share a hash.
CatalogBook devBook({TextPosition? position, double progress = 0}) => testBook(
  position: position,
  progress: progress,
  hash: sha256
      .convert(
        utf8.encode(
          '${DateTime.now().microsecondsSinceEpoch}-'
          '${Random.secure().nextInt(1 << 32)}',
        ),
      )
      .toString(),
);

/// Purges [cloudBookId] from dev when the current test tears down.
void deleteDevBookAfterTest(HttpIllustrationApi api, String cloudBookId) =>
    addTearDown(() => api.deleteBook(cloudBookId, interactive: false));
