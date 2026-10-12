import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../atomic_json_file.dart';
import '../catalog/book_storage.dart';
import '../catalog/catalog_book.dart';
import 'analysis_protocol.dart';
import 'analysis_result.dart';
import 'analysis_limits.dart';
import 'analysis_model.dart';
import 'book_analysis_state.dart';
import 'store.dart';

/// Exact-import analysis sidecars, separate from illustration caches and consent.
///
/// A state's AtomicJsonFile queue also serializes its page writes and account
/// cleanup, including across instances. Pages retain their compact wire JSON;
/// checksums never depend on a reconstructed DTO's field order.
class FileAnalysisStore implements AnalysisStore, AnalysisWriteFence {
  /// [isCurrent] can fence state writes before a coordinator registers its hooks.
  FileAnalysisStore(
    this.root, {
    bool Function(CatalogBook, BookAnalysisState)? isCurrent,
  }) : _stateEligible = isCurrent;

  /// Private catalog root owning every accepted exact import.
  final Directory root;
  bool Function(CatalogBook, BookAnalysisState)? _stateEligible;
  bool Function(CatalogBook, String)? _pageEligible;
  final _pending = <Future<void>>{};
  static final _hex = RegExp(r'^[a-f0-9]{64}$');
  static final _bookId = RegExp(r'^[a-f0-9]{40}$');
  static final _pageId = RegExp(
    '^(${AnalysisResultPageKind.values.map((kind) => kind.name).join('|')})-(0|[1-9][0-9]*)\$',
  );

  @override
  void setWriteEligibility({
    bool Function(CatalogBook, BookAnalysisState)? state,
    bool Function(CatalogBook, String)? page,
  }) {
    _stateEligible = state;
    _pageEligible = page;
  }

  Directory _directory(CatalogBook book) =>
      featureDirectory(root, book, 'analysis');

  AtomicJsonFile _stateFile(CatalogBook book) {
    final file = AtomicJsonFile(File('${_directory(book).path}/state.json'));
    _regularGenerations(file.file);
    return file;
  }

  AtomicJsonFile _pageFile(
    CatalogBook book,
    String generationId,
    String pageId,
  ) {
    _identity(generationId);
    if (!_pageId.hasMatch(pageId)) {
      throw const FormatException('Invalid analysis page identity.');
    }
    final pages = Directory('${_directory(book).path}/pages');
    final generation = Directory('${pages.path}/$generationId');
    _regularDirectory(pages);
    _regularDirectory(generation);
    final file = AtomicJsonFile(File('${generation.path}/$pageId.json'));
    _regularGenerations(file.file);
    return file;
  }

  @override
  Future<BookAnalysisState?> loadState(CatalogBook book) async {
    try {
      return await _readState(book, _stateFile(book));
    } on FormatException {
      return null;
    }
  }

  Future<BookAnalysisState?> _readState(
    CatalogBook book,
    AtomicJsonFile file,
  ) async {
    final stored = await file.read((json) {
      final state = BookAnalysisState.fromJson(json);
      _validateState(book, state);
      return state;
    });
    return stored?.value;
  }

  @override
  Future<void> saveState(CatalogBook book, BookAnalysisState state) {
    _validateState(book, state);
    // Snapshot before any await; caller-owned lists/maps cannot change a write.
    final snapshot = BookAnalysisState.fromJson(
      (jsonDecode(jsonEncode(state.toJson())) as Map).cast<String, dynamic>(),
    );
    final file = _stateFile(book);
    return _track(
      file.update(() async {
        if (!_canState(book, state)) return null;
        if (snapshot.finalized != null) {
          for (final descriptor in snapshot.finalized!.pages) {
            final page = await _readPage(
              book,
              snapshot.finalized!.generationId,
              descriptor.pageId,
              snapshot,
              descriptor,
            );
            if (!_canState(book, state)) return null;
            if (page == null) {
              throw const FormatException(
                'Analysis pointer requires every durable valid result page.',
              );
            }
          }
        }
        return snapshot.toJson();
      }, isCurrent: () => _canState(book, state)),
    );
  }

  @override
  Future<void> savePage(
    CatalogBook book,
    String generationId,
    String pageId,
    AnalysisResultPage page,
  ) {
    final payload = page.serializedJson;
    final bytes = utf8.encode(payload);
    final decoded = AnalysisResultPage.fromJson(
      (jsonDecode(payload) as Map).cast<String, dynamic>(),
    );
    if (decoded.generationId != generationId ||
        decoded.pageId != pageId ||
        decoded.pageId != '${decoded.kind.name}-${decoded.ordinal}' ||
        bytes.length > analysisPageMaxBytes) {
      throw const FormatException(
        'Invalid analysis result page identity or size.',
      );
    }
    final checksum = sha256.convert(bytes).toString();
    final stateFile = _stateFile(book);
    final pageFile = _pageFile(book, generationId, pageId);
    return _track(
      stateFile.update(() async {
        final state = await _readState(book, stateFile);
        if (!_canPage(book, generationId)) return null;
        if (state == null) {
          throw const FormatException(
            'Analysis page requires a supported durable owner receipt.',
          );
        }
        final descriptor = _descriptor(state, generationId, pageId);
        if (descriptor == null ||
            descriptor.checksum != checksum ||
            descriptor.byteLength != bytes.length ||
            descriptor.kind != decoded.kind ||
            descriptor.ordinal != decoded.ordinal) {
          throw const FormatException(
            'Analysis page is not owned by the durable finalized receipt.',
          );
        }
        final envelope = {
          'bookHash': book.hash,
          'bookPath': book.path,
          'addedAt': book.addedAt.toUtc().toIso8601String(),
          'accountKey': state.accountKey,
          'generationId': generationId,
          'pageId': pageId,
          'checksum': checksum,
          'byteLength': bytes.length,
          'pageJson': payload,
        };
        await pageFile.update(() async {
          if (!_canPage(book, generationId)) return null;
          for (final suffix in ['', '.tmp', '.bak']) {
            final existing = await _raw(File('${pageFile.file.path}$suffix'));
            if (!_canPage(book, generationId)) return null;
            if (existing == null) continue;
            // Immutable means even a different owner's page at the same path is
            // never adopted or overwritten; account cleanup removes owned data.
            if (existing['pageJson'] != payload ||
                !_sameOwner(existing, book, state.accountKey) ||
                existing['generationId'] != generationId ||
                existing['pageId'] != pageId) {
              throw const FormatException(
                'Immutable analysis result page conflicts.',
              );
            }
          }
          final existing = await _readPage(
            book,
            generationId,
            pageId,
            state,
            descriptor,
          );
          if (!_canPage(book, generationId) || existing != null) return null;
          return envelope;
        }, isCurrent: () => _canPage(book, generationId));
        return null; // The state queue is held until the page transaction commits.
      }, isCurrent: () => _canPage(book, generationId)),
    );
  }

  @override
  Future<AnalysisResultPage?> loadPage(
    CatalogBook book,
    String generationId,
    String pageId,
  ) async {
    try {
      final state = await _readState(book, _stateFile(book));
      if (state == null) return null;
      final descriptor = _descriptor(state, generationId, pageId);
      if (descriptor == null) return null;
      return await _readPage(book, generationId, pageId, state, descriptor);
    } on FormatException {
      return null;
    }
  }

  Future<AnalysisResultPage?> _readPage(
    CatalogBook book,
    String generationId,
    String pageId,
    BookAnalysisState state,
    AnalysisResultPageDescriptor descriptor,
  ) async {
    final file = _pageFile(book, generationId, pageId);
    final stored = await file.read((json) {
      if (!_sameOwner(json, book, state.accountKey) ||
          json['generationId'] != generationId ||
          json['pageId'] != pageId ||
          json['checksum'] != descriptor.checksum ||
          json['byteLength'] != descriptor.byteLength) {
        return null;
      }
      final page = _decodeEnvelope(json);
      if (page.kind != descriptor.kind || page.ordinal != descriptor.ordinal) {
        return null;
      }
      return page;
    });
    return stored?.value;
  }

  AnalysisResultPageDescriptor? _descriptor(
    BookAnalysisState state,
    String generationId,
    String pageId,
  ) {
    if (state.accountKey == null) return null;
    final progress = state.progress;
    final finalized = state.finalized;
    final List<AnalysisResultPageDescriptor> pages;
    if (progress != null &&
        progress.status == AnalysisGenerationStatus.complete &&
        progress.finalizedRevision != null &&
        progress.accountKey == state.accountKey &&
        progress.generationId == generationId &&
        state.receipt?.generationId == generationId) {
      pages = progress.resultPages;
    } else if (finalized != null &&
        finalized.accountKey == state.accountKey &&
        finalized.generationId == generationId) {
      pages = finalized.pages;
    } else {
      return null;
    }
    for (final page in pages) {
      if (page.pageId == pageId) return page;
    }
    return null;
  }

  @override
  Future<void> clearAccountData(List<CatalogBook> books) =>
      _track(Future.wait(books.map(_clearBook)).then((_) {}));

  Future<void> _clearBook(CatalogBook book) async {
    final AtomicJsonFile file;
    try {
      file = _stateFile(book);
    } on FormatException {
      return;
    }
    await file.update(() async {
      final state = await _readState(book, file);
      if (state == null) return null;
      final pages = Directory('${_directory(book).path}/pages');
      if (FileSystemEntity.typeSync(pages.path, followLinks: false) ==
          FileSystemEntityType.directory) {
        await for (final generation in pages.list(followLinks: false)) {
          if (generation is! Directory ||
              !_hex.hasMatch(
                generation.uri.pathSegments.where((s) => s.isNotEmpty).last,
              ) ||
              FileSystemEntity.typeSync(generation.path, followLinks: false) !=
                  FileSystemEntityType.directory) {
            continue;
          }
          final generationId = generation.uri.pathSegments
              .where((s) => s.isNotEmpty)
              .last;
          await for (final entry in generation.list(followLinks: false)) {
            final name = entry.uri.pathSegments.last;
            final match = RegExp(r'^(.+)\.json(?:\.tmp|\.bak)?$')
                .firstMatch(name);
            if (match == null || !_pageId.hasMatch(match.group(1)!)) continue;
            final json = await _raw(File(entry.path));
            if (json == null ||
                !_sameImport(json, book) ||
                json['generationId'] != generationId ||
                json['pageId'] != match.group(1)) {
              continue;
            }
            try {
              _identity(json['accountKey'] as String);
              _decodeEnvelope(json);
              // Synchronous unlink follows validation without an invalidation gap.
              if (FileSystemEntity.typeSync(entry.path, followLinks: false) ==
                  FileSystemEntityType.file) {
                File(entry.path).deleteSync();
              }
            } on FormatException {
              continue;
            } on TypeError {
              continue;
            }
          }
        }
      }
      for (final suffix in ['', '.tmp', '.bak']) {
        final candidate = File('${file.file.path}$suffix');
        final json = await _raw(candidate);
        if (json == null) continue;
        try {
          _validateState(book, BookAnalysisState.fromJson(json));
          if (FileSystemEntity.typeSync(candidate.path, followLinks: false) ==
              FileSystemEntityType.file) {
            candidate.deleteSync();
          }
        } on Object {
          continue;
        }
      }
      return null;
    });
  }

  @override
  Future<void> flush() async {
    while (_pending.isNotEmpty) {
      await Future.wait(List<Future<void>>.of(_pending));
    }
  }

  Future<void> _track(Future<void> operation) {
    _pending.add(operation);
    operation.then<void>(
      (_) {
        _pending.remove(operation);
      },
      onError: (Object _, StackTrace _) {
        _pending.remove(operation);
      },
    );
    return operation;
  }

  bool _canState(CatalogBook book, BookAnalysisState state) {
    if (_stateEligible != null && !_stateEligible!(book, state)) return false;
    try {
      _stateFile(book);
      return true;
    } on FormatException {
      return false;
    }
  }

  bool _canPage(CatalogBook book, String generationId) {
    if (_pageEligible != null && !_pageEligible!(book, generationId)) {
      return false;
    }
    try {
      _stateFile(book);
      _regularDirectory(Directory('${_directory(book).path}/pages'));
      _regularDirectory(
        Directory('${_directory(book).path}/pages/$generationId'),
      );
      return true;
    } on FormatException {
      return false;
    }
  }

  void _validateState(CatalogBook book, BookAnalysisState state) {
    if (!state.matchesBook(book) ||
        state.model != analysisModel ||
        state.manifestPagesUploaded < 0) {
      throw const FormatException('Invalid analysis state import.');
    }
    if (state.accountKey != null) _identity(state.accountKey!);
    if (state.documentDigest != null) _identity(state.documentDigest!);
    if (state.cloudBookId != null && !_bookId.hasMatch(state.cloudBookId!)) {
      throw const FormatException('Invalid analysis cloud book identity.');
    }
    if (state.receipt != null) {
      _identity(state.receipt!.generationId);
      if (state.receipt!.jobId != null) _identity(state.receipt!.jobId!);
      if (state.accountKey == null || state.cloudBookId == null) {
        throw const FormatException('Analysis receipt requires its owner.');
      }
    }
    final progress = state.progress;
    if (progress != null) {
      if (progress.accountKey != state.accountKey ||
          progress.bookId != state.cloudBookId ||
          progress.generationId != state.receipt?.generationId ||
          progress.documentDigest != state.documentDigest ||
          progress.processedChunks < 0 ||
          progress.processedChunks > progress.requiredChunks ||
          progress.processedUnits < 0 ||
          progress.processedUnits > progress.requiredUnits) {
        throw const FormatException(
          'Analysis progress does not belong to this state.',
        );
      }
      if (progress.finalizedRevision != null) {
        _identity(progress.finalizedRevision!);
      }
      if (progress.status == AnalysisGenerationStatus.complete &&
          (progress.processedChunks != progress.requiredChunks ||
              progress.processedUnits != progress.requiredUnits ||
              progress.finalizedRevision == null)) {
        throw const FormatException(
          'Complete analysis progress requires complete coverage.',
        );
      }
      _validateDescriptors(progress.resultPages);
    }
    final finalized = state.finalized;
    if (finalized != null) {
      _identity(finalized.generationId);
      _identity(finalized.revision);
      _identity(finalized.documentDigest);
      if (finalized.accountKey != state.accountKey) {
        throw const FormatException(
          'Analysis finalized pointer has a different owner.',
        );
      }
      _validateDescriptors(finalized.pages);
    }
    if (state.status == BookAnalysisStatus.complete &&
        (finalized == null ||
            finalized.generationId != state.receipt?.generationId ||
            finalized.documentDigest != state.documentDigest)) {
      throw const FormatException(
        'Complete analysis requires a matching finalized local pointer.',
      );
    }
  }

  void _validateDescriptors(List<AnalysisResultPageDescriptor> pages) {
    final ids = <String>{};
    for (final page in pages) {
      _identity(page.checksum);
      if (!ids.add(page.pageId) ||
          page.ordinal < 0 ||
          page.pageId != '${page.kind.name}-${page.ordinal}' ||
          page.byteLength < 1 ||
          page.byteLength > analysisPageMaxBytes) {
        throw const FormatException('Invalid analysis result descriptor.');
      }
    }
  }

  AnalysisResultPage _decodeEnvelope(Map<String, dynamic> json) {
    if (json['pageJson'] is! String) {
      throw const FormatException('Unsupported analysis page envelope.');
    }
    final payload = json['pageJson'] as String;
    final bytes = utf8.encode(payload);
    if (bytes.length > analysisPageMaxBytes ||
        bytes.length != json['byteLength'] ||
        sha256.convert(bytes).toString() != json['checksum']) {
      throw const FormatException('Analysis page checksum or size mismatch.');
    }
    final page = AnalysisResultPage.fromJson(
      (jsonDecode(payload) as Map).cast<String, dynamic>(),
    );
    if (page.generationId != json['generationId'] ||
        page.pageId != json['pageId'] ||
        page.pageId != '${page.kind.name}-${page.ordinal}') {
      throw const FormatException('Analysis page envelope identity mismatch.');
    }
    return page;
  }

  bool _sameImport(Map<String, dynamic> json, CatalogBook book) =>
      json['bookHash'] == book.hash &&
      json['bookPath'] == book.path &&
      json['addedAt'] == book.addedAt.toUtc().toIso8601String();

  bool _sameOwner(
    Map<String, dynamic> json,
    CatalogBook book,
    String? accountKey,
  ) =>
      accountKey != null &&
      _sameImport(json, book) &&
      json['accountKey'] == accountKey;

  Future<Map<String, dynamic>?> _raw(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    try {
      final json = jsonDecode(await file.readAsString());
      return json is Map ? json.cast<String, dynamic>() : null;
    } on FormatException {
      return null;
    }
  }

  void _identity(String value) {
    if (!_hex.hasMatch(value)) {
      throw const FormatException('Invalid analysis identity.');
    }
  }

  void _regularDirectory(Directory directory) {
    final kind = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (kind != FileSystemEntityType.notFound &&
        kind != FileSystemEntityType.directory) {
      throw const FormatException('Analysis storage cannot be a link.');
    }
  }

  void _regularGenerations(File file) {
    for (final suffix in ['', '.tmp', '.bak']) {
      final kind = FileSystemEntity.typeSync(
        '${file.path}$suffix',
        followLinks: false,
      );
      if (kind != FileSystemEntityType.notFound &&
          kind != FileSystemEntityType.file) {
        throw const FormatException(
          'Analysis generations must be regular files.',
        );
      }
    }
  }
}
