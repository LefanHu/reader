import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'document.dart';
import 'normalized_book_files.dart';
import 'text_section.dart';

/// Disk boundary used by rendering and illustration indexing alike.
///
/// Each load decodes on a short-lived isolate so JSON parsing stays off the UI
/// isolate. Work already running on a background isolate uses
/// [InlineTextDocumentStore] instead of spawning one isolate per load.
class TextDocumentStore {
  /// Loads only the immutable document manifest.
  Future<TextDocument> load(String sourcePath) =>
      Isolate.run(() => _decodeDocument(sourcePath));

  /// Loads a generated section ID; source paths never become filesystem paths.
  Future<TextSection> loadSection(String sourcePath, String id) =>
      Isolate.run(() => _decodeSection(sourcePath, id));
}

/// The same disk boundary, decoding on the calling isolate. Only for code that
/// already runs off the UI isolate.
class InlineTextDocumentStore extends TextDocumentStore {
  @override
  Future<TextDocument> load(String sourcePath) => _decodeDocument(sourcePath);

  @override
  Future<TextSection> loadSection(String sourcePath, String id) =>
      _decodeSection(sourcePath, id);
}

Future<TextDocument> _decodeDocument(String sourcePath) async {
  final path = NormalizedBookFiles.document(File(sourcePath).parent.path);
  return TextDocument.fromJson(
    (jsonDecode(await File(path).readAsString()) as Map)
        .cast<String, dynamic>(),
  );
}

Future<TextSection> _decodeSection(String sourcePath, String id) async {
  final path = NormalizedBookFiles.section(File(sourcePath).parent.path, id);
  final section = TextSection.fromJson(
    (jsonDecode(await File(path).readAsString()) as Map)
        .cast<String, dynamic>(),
  );
  if (section.id != id) {
    throw const FormatException(
      'Section identity mismatch. Reimport this book.',
    );
  }
  return section;
}
