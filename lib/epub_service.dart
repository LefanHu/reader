import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flureadium/flureadium.dart';

import 'models.dart';

const maxEpubBytes = 100 * 1024 * 1024;

abstract interface class ReadiumEngine {
  Future<Publication> load(String path);
  Future<Publication> open(String path);
  Future<void> close();
  void setDefaults(EPUBPreferences preferences);
  Future<void> setPreferences(EPUBPreferences preferences);
  Future<void> goLeft();
  Future<void> goRight();
  Future<void> previousChapter();
  Future<void> nextChapter();
  Future<bool> goByLink(Link link, Publication publication);
}

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

class ImportCandidate {
  const ImportCandidate({
    required this.name,
    required this.size,
    required this.readBytes,
  });
  final String name;
  final int size;
  final Future<Uint8List> Function() readBytes;
}

abstract interface class EpubPicker {
  Future<List<ImportCandidate>> pick();
}

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

class EpubImporter {
  EpubImporter({required this.root, required this.engine});
  final Directory root;
  final ReadiumEngine engine;

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
      return null;
    }
  }
}
