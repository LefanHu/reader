import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:characters/characters.dart';

import 'document.dart';

final _letterOrNumber = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _mark = RegExp(r'^\p{M}+$', unicode: true);

/// Deterministic estimate over reader text, without dictionary segmentation.
/// Han and kana graphemes count individually; other letter/number runs count
/// once. Unspaced Thai and similar scripts therefore underestimate word counts.
/// Block boundaries delimit runs; emoji and standalone punctuation do not count.
int approximateWordCount(String text) {
  var count = 0;
  var inWord = false;
  var apostrophe = false;
  for (final cluster in text.characters) {
    final rune = cluster.runes.first;
    final ideograph =
        (rune >= 0x3400 && rune <= 0x4dbf) ||
        (rune >= 0x4e00 && rune <= 0x9fff) ||
        (rune >= 0xf900 && rune <= 0xfaff) ||
        (rune >= 0x20000 && rune <= 0x323af) ||
        (rune >= 0x3040 && rune <= 0x30ff) ||
        (rune >= 0x1b000 && rune <= 0x1b16f) ||
        (rune >= 0x31f0 && rune <= 0x31ff) ||
        (rune >= 0xff66 && rune <= 0xff9d);
    if (ideograph && _letterOrNumber.hasMatch(cluster)) {
      count++;
      inWord = false;
      apostrophe = false;
    } else if (_letterOrNumber.hasMatch(cluster) &&
        !cluster.contains('\u20e3') &&
        !cluster.contains('\ufe0f')) {
      if (!inWord) count++;
      inWord = true;
      apostrophe = false;
    } else if (_mark.hasMatch(cluster)) {
      // Combining-only clusters never create a new word.
    } else if ((cluster == "'" || cluster == '’') && inWord && !apostrophe) {
      apostrophe = true;
    } else {
      inWord = false;
      apostrophe = false;
    }
  }
  return count;
}

/// Counts the exact normalized blocks used by drawing and illustration jobs.
int countSectionWords(TextSection section) => section.blocks.fold(
  0,
  (sum, block) => sum + approximateWordCount(block.text),
);

/// Injectable boundary for background backfill from existing normalized books.
abstract interface class BookWordCounter {
  /// Loads bounded sections sequentially, without reparsing the source book.
  Future<int> count(String sourcePath);
}

/// Performs disk decoding and counting on one worker isolate per book.
/// Callers supply validated app-owned catalog paths; section IDs are validated
/// by the document manifest before becoming local sidecar filenames.
class FileBookWordCounter implements BookWordCounter {
  @override
  Future<int> count(String sourcePath) => Isolate.run(() async {
    final root = File(sourcePath).parent.path;
    final document = TextDocument.fromJson(
      (jsonDecode(await File('$root/document.json').readAsString()) as Map)
          .cast<String, dynamic>(),
    );
    var count = 0;
    for (final summary in document.sections) {
      final section = TextSection.fromJson(
        (jsonDecode(
          await File('$root/text/${summary.id}.json').readAsString(),
        ) as Map).cast<String, dynamic>(),
      );
      if (section.id != summary.id) {
        throw const FormatException('Section identity mismatch.');
      }
      count += countSectionWords(section);
    }
    return count;
  });
}

/// Stable, compact English grouping used beside titles in the library.
String wordCountLabel(int count) {
  final digits = count.toString();
  return '≈ ${digits.replaceAllMapped(RegExp(r"\B(?=(\d{3})+(?!\d))"), (_) => ',')} words';
}
