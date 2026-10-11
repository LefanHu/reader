import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'book_word_counter.dart';
import 'document.dart';
import 'normalized_book_files.dart';
import 'text_section.dart';
import 'word_count.dart';

/// Performs disk decoding and counting on one worker isolate per book.
/// Callers supply validated app-owned catalog paths; section IDs are validated
/// before becoming local sidecar filenames.
class FileBookWordCounter implements BookWordCounter {
  @override
  Future<int> count(String sourcePath) => Isolate.run(() async {
    final root = File(sourcePath).parent.path;
    final document = TextDocument.fromJson(
      (jsonDecode(
        await File(NormalizedBookFiles.document(root)).readAsString(),
      ) as Map).cast<String, dynamic>(),
    );
    var count = 0;
    for (final summary in document.sections) {
      final section = TextSection.fromJson(
        (jsonDecode(
          await File(NormalizedBookFiles.section(root, summary.id))
              .readAsString(),
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
