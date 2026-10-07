import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';

import 'models.dart';
import 'text/parser.dart';
import 'text/word_count.dart';

/// Lazy source selection so a multi-file import reads one book at a time.
class ImportCandidate {
  /// Picker metadata is checked again after source bytes are read.
  const ImportCandidate({
    required this.name,
    required this.size,
    required this.readBytes,
  });

  /// Original filename, also the TXT title fallback.
  final String name;

  /// Reported byte length, or -1 if unavailable.
  final int size;

  /// Reads the selection while its platform access is still available.
  final Future<Uint8List> Function() readBytes;
}

/// Native file selection boundary, replaceable in tests.
abstract interface class BookPicker {
  /// Selects EPUB and TXT files without eagerly reading all selections.
  Future<List<ImportCandidate>> pick();
}

/// Platform document picker supporting multiple text-focused book imports.
class NativeBookPicker implements BookPicker {
  @override
  Future<List<ImportCandidate>> pick() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Import books',
      type: FileType.custom,
      allowedExtensions: const ['epub', 'txt'],
    );
    return [
      for (final file in files)
        ImportCandidate(
          name: file.name,
          size: await file.length() ?? -1,
          readBytes: file.readAsBytes,
        ),
    ];
  }
}

/// Validates untrusted books and commits source plus normalized text atomically.
class BookImporter {
  /// Storage is private Application Support; picker paths are never persisted.
  BookImporter({required this.root});

  /// Catalog root containing content-addressed book directories.
  final Directory root;

  /// Imports one candidate with isolated errors and no partial catalog entries.
  Future<({CatalogBook? book, ImportResult result})> import(
    ImportCandidate candidate,
    Set<String> existingHashes,
  ) async {
    Directory? staging;
    try {
      if (!RegExp(
        r'\.(epub|txt)$',
        caseSensitive: false,
      ).hasMatch(candidate.name)) {
        throw const FormatException('Only EPUB and TXT files are supported.');
      }
      if (candidate.size > maxBookBytes) {
        throw const FormatException('The file is larger than 100 MB.');
      }
      final bytes = await candidate.readBytes();
      if (bytes.length > maxBookBytes) {
        throw const FormatException('The file is larger than 100 MB.');
      }
      final hash = await Isolate.run(() => sha256.convert(bytes).toString());
      if (existingHashes.contains(hash)) {
        return (
          book: null,
          result: ImportResult(candidate.name, ImportStatus.duplicate),
        );
      }
      final books = Directory('${root.path}/books');
      await books.create(recursive: true);
      staging = Directory('${books.path}/$hash.importing');
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create();
      final stagedPath = staging.path;
      final name = candidate.name;
      final extension = name.toLowerCase().endsWith('.txt') ? 'txt' : 'epub';
      // Parsing, hashing and sidecar writes stay off the UI isolate. Only the
      // small document manifest and count cross back after all checks succeed.
      final normalized = await Isolate.run(() async {
        final parsed = parseTextBook(bytes, name, hash);
        await File('$stagedPath/book.$extension')
            .writeAsBytes(bytes, flush: true);
        await Directory('$stagedPath/text').create();
        for (final section in parsed.sections) {
          await File('$stagedPath/text/${section.id}.json')
              .writeAsString(jsonEncode(section.toJson()), flush: true);
        }
        await File('$stagedPath/document.json')
            .writeAsString(jsonEncode(parsed.document.toJson()), flush: true);
        if (parsed.cover != null) {
          await File('$stagedPath/cover.${parsed.coverExtension}')
              .writeAsBytes(parsed.cover!, flush: true);
        }
        return (
          document: parsed.document,
          wordCount: parsed.sections.fold<int>(
            0,
            (sum, section) => sum + countSectionWords(section),
          ),
        );
      });
      final document = normalized.document;
      final destination = Directory('${books.path}/$hash');
      if (await destination.exists()) await destination.delete(recursive: true);
      await staging.rename(destination.path);
      staging = null;
      final covers = ['png', 'jpg']
          .map((ext) => File('${destination.path}/cover.$ext'))
          .where((file) => file.existsSync());
      final book = CatalogBook(
        hash: hash,
        fileName: candidate.name,
        path: '${destination.path}/book.$extension',
        title: document.title,
        wordCount: normalized.wordCount,
        authors: document.authors,
        language: document.language,
        identifier: document.identifier,
        coverPath: covers.firstOrNull?.path,
        addedAt: DateTime.now(),
      );
      return (
        book: book,
        result: ImportResult(candidate.name, ImportStatus.imported),
      );
    } on Object catch (error) {
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      return (
        book: null,
        result: ImportResult(
          candidate.name,
          ImportStatus.failed,
          message: error is FormatException
              ? error.message
              : 'Could not import this book: $error',
        ),
      );
    }
  }
}
