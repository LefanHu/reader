import 'dart:async';

import 'package:reader/text/text_section.dart' as text;

import '../fixtures/text_documents.dart';
import 'memory_document_store.dart';

/// Simulates chapter I/O that can fail or complete after a navigation override.
class DelayedDocumentStore extends MemoryDocumentStore {
  /// Supplies the original three single-page chapters.
  DelayedDocumentStore() : super(sections: singlePageSections());

  /// Optional completion barrier for loading the second chapter.
  Completer<void>? pending;

  /// Whether loading the second chapter throws its original failure.
  bool fail = false;

  @override
  Future<text.TextSection> loadSection(String sourcePath, String id) async {
    if (id == 's1') {
      if (fail) throw StateError('unavailable section');
      await pending?.future;
    }
    return super.loadSection(sourcePath, id);
  }
}
