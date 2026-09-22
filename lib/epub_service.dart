import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flureadium/flureadium.dart';

import 'models.dart';

/// Maximum accepted source size, checked before and after reading the file.
const maxEpubBytes = 100 * 1024 * 1024;

/// Narrow adapter around the native Readium session used by application code.
///
/// Keeping the plugin behind this interface makes import and reader behavior
/// testable without loading a platform view or invoking method channels.
abstract interface class ReadiumEngine {
  /// Parses a publication for validation and metadata extraction.
  Future<Publication> load(String path);

  /// Opens a parsed publication as the active reading session.
  Future<Publication> open(String path);

  /// Releases the active native publication and its local content server.
  Future<void> close();

  /// Sets preferences that must be present before a navigator is created.
  void setDefaults(EPUBPreferences preferences);

  /// Applies preferences to an existing navigator.
  Future<void> setPreferences(EPUBPreferences preferences);

  /// Moves one visual page or screen toward the publication's left edge.
  Future<void> goLeft();

  /// Moves one visual page or screen toward the publication's right edge.
  Future<void> goRight();

  /// Navigates to the previous reading-order resource.
  Future<void> previousChapter();

  /// Navigates to the next reading-order resource.
  Future<void> nextChapter();

  /// Navigates to an original publication link, including its fragment.
  Future<bool> goByLink(Link link, Publication publication);
}

/// Production [ReadiumEngine] backed by Flureadium's singleton session.
class FlureadiumEngine implements ReadiumEngine {
  final Flureadium _readium = Flureadium();

  @override
  Future<Publication> load(String path) => _readium.loadPublication(path);
  @override
  Future<Publication> open(String path) => _readium.openPublication(path);
  @override
  Future<void> close() => _readium.closePublication();
  @override
  void setDefaults(EPUBPreferences preferences) =>
      _readium.setDefaultPreferences(preferences);
  @override
  Future<void> setPreferences(EPUBPreferences preferences) =>
      _readium.setEPUBPreferences(preferences);
  @override
  Future<void> goLeft() => _readium.goLeft();
  @override
  Future<void> goRight() => _readium.goRight();
  @override
  Future<void> previousChapter() => _readium.skipToPrevious();
  @override
  Future<void> nextChapter() => _readium.skipToNext();
  @override
  Future<bool> goByLink(Link link, Publication publication) =>
      _readium.goByLink(link, publication);
}

/// Lazy representation of a selected source file.
///
/// Bytes are deferred until the importer is ready to process this candidate,
/// which keeps multi-file selection from loading every EPUB into memory at once.
class ImportCandidate {
  /// Creates a lazy candidate from picker metadata and a byte reader.
  const ImportCandidate({
    required this.name,
    required this.size,
    required this.readBytes,
  });

  /// Display name supplied by the document picker.
  final String name;

  /// Picker-reported byte length, or `-1` when unavailable.
  final int size;

  /// Reads the complete source only when this candidate is processed.
  final Future<Uint8List> Function() readBytes;
}

/// Boundary around the native document picker.
abstract interface class EpubPicker {
  /// Opens the picker and returns selected files in platform order.
  Future<List<ImportCandidate>> pick();
}

/// Selects one or more EPUB files through the platform document picker.
class NativeEpubPicker implements EpubPicker {
  @override
  Future<List<ImportCandidate>> pick() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Import EPUBs',
      type: FileType.custom,
      allowedExtensions: const ['epub'],
    );
    final candidates = <ImportCandidate>[];
    for (final file in files) {
      candidates.add(
        ImportCandidate(
          name: file.name,
          size: await file.length() ?? -1,
          readBytes: file.readAsBytes,
        ),
      );
    }
    return candidates;
  }
}

/// Validates and commits selected EPUBs into content-addressed app storage.
///
/// Each import is staged under a temporary directory. No catalog-ready path is
/// returned until Readium has parsed the book and all policy checks pass.
class EpubImporter {
  /// Creates an importer rooted in private app storage.
  EpubImporter({required this.root, required this.engine});

  /// Application-support directory containing the catalog and books folder.
  final Directory root;

  /// Readium adapter used to parse and inspect staged books.
  final ReadiumEngine engine;

  /// Imports [candidate], or reports a per-file failure without partial files.
  ///
  /// [existingHashes] identifies exact byte-for-byte duplicates; books with
  /// identical human-readable metadata remain valid independent entries.
  Future<({CatalogBook? book, ImportResult result})> import(
    ImportCandidate candidate,
    Set<String> existingHashes,
  ) async {
    Directory? staging;
    try {
      if (!candidate.name.toLowerCase().endsWith('.epub')) {
        throw const FormatException('Only EPUB files are supported.');
      }
      if (candidate.size > maxEpubBytes) {
        throw const FormatException('The file is larger than 100 MB.');
      }
      final bytes = await candidate.readBytes();
      if (bytes.length > maxEpubBytes) {
        throw const FormatException('The file is larger than 100 MB.');
      }
      final hash = sha256.convert(bytes).toString();
      if (existingHashes.contains(hash)) {
        return (
          book: null,
          result: ImportResult(candidate.name, ImportStatus.duplicate),
        );
      }

      // Readium must inspect only our private staged copy. The picker URL may
      // be security-scoped or disappear after the selection session ends.
      final booksRoot = Directory('${root.path}/books');
      await booksRoot.create(recursive: true);
      staging = Directory('${booksRoot.path}/$hash.importing');
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create();
      final stagedBook = File('${staging.path}/book.epub');
      await stagedBook.writeAsBytes(bytes, flush: true);

      final publication = await engine.load(stagedBook.path);
      _validate(publication);
      final coverPath = await _cacheCover(publication, staging);
      // Renaming within Application Support commits the complete directory in
      // one filesystem operation before the controller writes its catalog row.
      final finalDirectory = Directory('${booksRoot.path}/$hash');
      if (await finalDirectory.exists()) {
        await finalDirectory.delete(recursive: true);
      }
      await staging.rename(finalDirectory.path);
      staging = null;

      final rawTitle = publication.metadata.title.trim();
      final fallbackTitle = candidate.name.replaceFirst(
        RegExp(r'\.epub$', caseSensitive: false),
        '',
      );
      final book = CatalogBook(
        hash: hash,
        fileName: candidate.name,
        path: '${finalDirectory.path}/book.epub',
        title: rawTitle.isEmpty ? fallbackTitle : rawTitle,
        authors: publication.metadata.authors
            .map((author) => author.name.trim())
            .where((name) => name.isNotEmpty)
            .toList(),
        identifier: publication.metadata.identifier,
        language: publication.metadata.language,
        coverPath: coverPath == null
            ? null
            : '${finalDirectory.path}/${File(coverPath).uri.pathSegments.last}',
        addedAt: DateTime.now(),
      );
      return (
        book: book,
        result: ImportResult(candidate.name, ImportStatus.imported),
      );
    } on Object catch (error) {
      // Import failures are isolated to one selection and never leave a staged
      // directory that could be mistaken for a committed publication.
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      final message = error is FormatException
          ? error.message
          : error.toString().replaceFirst(RegExp(r'^Exception: '), '');
      return (
        book: null,
        result: ImportResult(
          candidate.name,
          ImportStatus.failed,
          message: message,
        ),
      );
    }
  }

  void _validate(Publication publication) {
    // Imported publications are untrusted. Restrict the accepted subset to
    // reflowable, local, non-scripted, non-DRM content before rendering it.
    if (publication.readingOrder.isEmpty) {
      throw const FormatException('This EPUB has no readable content.');
    }
    if (publication.metadata.rendition?.layout == EpubLayout.fixed ||
        publication.readingOrder.any(
          (link) => link.properties.layout == EpubLayout.fixed,
        )) {
      throw const FormatException('Fixed-layout EPUBs are not supported.');
    }
    final links = _allLinks(publication);
    if (links.any(
      (link) =>
          (link.properties.contains ?? const []).contains('scripted') ||
          link.type == 'application/javascript' ||
          link.href.toLowerCase().endsWith('.js'),
    )) {
      throw const FormatException('Scripted EPUB content is not supported.');
    }
    if (links.any((link) {
      final uri = Uri.tryParse(link.href);
      return uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host != 'localhost' &&
          uri.host != '127.0.0.1' &&
          uri.host != '::1';
    })) {
      throw const FormatException(
        'EPUBs with remote resources are not supported.',
      );
    }
    if (publication.readingOrder.any(
          (link) => link.properties.encryption != null,
        ) ||
        publication.linksWithRel('license').isNotEmpty) {
      throw const FormatException('DRM-protected EPUBs are not supported.');
    }
  }

  Iterable<Link> _allLinks(Publication publication) sync* {
    // Security-sensitive resources can appear in alternates or nested TOCs,
    // not only in the top-level reading order.
    Iterable<Link> descend(Iterable<Link> links) sync* {
      for (final link in links) {
        yield link;
        yield* descend(link.alternates);
        yield* descend(link.children);
      }
    }

    yield* descend(publication.links);
    yield* descend(publication.readingOrder);
    yield* descend(publication.resources);
    yield* descend(publication.tableOfContents);
  }

  Future<String?> _cacheCover(Publication publication, Directory target) async {
    final uri = publication.coverUri;
    if (uri == null) return null;
    try {
      Uint8List bytes;
      // Readium exposes archive resources through a loopback content server.
      // Never fetch arbitrary network URLs while importing an untrusted book.
      if (uri.scheme == 'http' &&
          {'localhost', '127.0.0.1', '::1'}.contains(uri.host)) {
        final client = HttpClient();
        try {
          final response = await (await client.getUrl(uri)).close();
          if (response.statusCode != HttpStatus.ok) return null;
          bytes = Uint8List.fromList(
            await response.fold<List<int>>([], (a, b) => a..addAll(b)),
          );
        } finally {
          client.close(force: true);
        }
      } else if (uri.scheme == 'file') {
        bytes = await File.fromUri(uri).readAsBytes();
      } else {
        return null;
      }
      final extension = publication.coverLink?.type == 'image/png'
          ? 'png'
          : 'jpg';
      final file = File('${target.path}/cover.$extension');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } on Object {
      // A missing or unreadable cover is non-fatal; the UI generates one.
      return null;
    }
  }
}
