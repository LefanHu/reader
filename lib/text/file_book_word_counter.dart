import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'book_word_counter.dart';
import 'document.dart';
import 'text_section.dart';
import 'word_count.dart';

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
