import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'document.dart';
import 'text_section.dart';

/// Disk boundary used by rendering and illustration indexing alike.
class TextDocumentStore {
  /// Loads only the immutable document manifest.
  Future<TextDocument> load(String sourcePath) async {
    final path = '${File(sourcePath).parent.path}/document.json';
    return Isolate.run(
      () async => TextDocument.fromJson(
        (jsonDecode(await File(path).readAsString()) as Map)
            .cast<String, dynamic>(),
      ),
    );
  }

  /// Loads a generated section ID; source paths never become filesystem paths.
  Future<TextSection> loadSection(String sourcePath, String id) async {
    if (!RegExp(r'^s[0-9]+$').hasMatch(id)) {
      throw const FormatException('Invalid section ID.');
    }
    final path = '${File(sourcePath).parent.path}/text/$id.json';
    return Isolate.run(() async {
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
    });
  }
}
