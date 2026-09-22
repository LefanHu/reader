// The indexer contract and security invariants are documented on its types.
// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

import 'models.dart';

/// Maximum expanded EPUB data accepted by the illustration indexer.
const maxIllustrationExpandedBytes = 300 * 1024 * 1024;

/// Maximum number of ZIP entries inspected while building a text index.
const maxIllustrationArchiveEntries = 10000;

/// Maximum compressed EPUB size accepted by the illustration indexer.
const maxIllustrationArchiveBytes = 100 * 1024 * 1024;

/// Extracts a bounded, deterministic paragraph index from an imported EPUB.
///
/// The source archive remains immutable. Only OPF spine XHTML is decompressed,
/// and archive limits are checked before any untrusted entry is read.
abstract interface class EpubTextIndexer {
  Future<BookTextIndex> index({
    required String epubPath,
    required String bookHash,
  });
}

/// ZIP/HTML implementation used by the production illustration pipeline.
class ArchiveEpubTextIndexer implements EpubTextIndexer {
  @override
  Future<BookTextIndex> index({
    required String epubPath,
    required String bookHash,
  }) async {
    final source = File(epubPath);
    if (await source.length() > maxIllustrationArchiveBytes) {
      throw const FormatException('The EPUB archive is too large.');
    }
    final bytes = await source.readAsBytes();
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    _validateDirectory(directory);
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    _validateArchive(archive);
    final files = <String, ArchiveFile>{};
    for (final entry in archive.files.where((entry) => entry.isFile)) {
      files[_safePath(entry.name)] = entry;
    }

    final container = _required(files, 'META-INF/container.xml');
    final containerXml = XmlDocument.parse(_decode(container));
    final rootfile = containerXml.descendants
        .whereType<XmlElement>()
        .where((element) => element.localName == 'rootfile')
        .firstOrNull;
    final rawOpfPath = rootfile?.getAttribute('full-path');
    if (rawOpfPath == null || rawOpfPath.trim().isEmpty) {
      throw const FormatException('The EPUB container has no package file.');
    }
    final opfPath = _safePath(rawOpfPath);
    final opfXml = XmlDocument.parse(_decode(_required(files, opfPath)));
    final manifest = <String, ({String href, String mediaType})>{};
    for (final item in opfXml.descendants.whereType<XmlElement>().where(
      (element) => element.localName == 'item',
    )) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id == null || href == null) continue;
      manifest[id] = (
        href: href.split('#').first,
        mediaType: item.getAttribute('media-type') ?? '',
      );
    }

    final opfDirectory = opfPath.contains('/')
        ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1)
        : '';
    final chapters = <ChapterTextIndex>[];
    final spineItems = opfXml.descendants.whereType<XmlElement>().where(
      (element) => element.localName == 'itemref',
    );
    for (final itemref in spineItems) {
      final idref = itemref.getAttribute('idref');
      final item = idref == null ? null : manifest[idref];
      if (item == null ||
          !{'application/xhtml+xml', 'text/html'}.contains(item.mediaType)) {
        continue;
      }
      final archivePath = _resolvePath(opfDirectory, item.href);
      final entry = files[archivePath];
      if (entry == null) continue;
      final parsed = html.parse(_decode(entry));
      _removeUnsafeAndHiddenContent(parsed);
      final blocks = parsed.querySelectorAll(
        'h1,h2,h3,h4,h5,h6,p,blockquote,li,figcaption,pre,img[alt]',
      );
      final raw = <({String text, String selector})>[];
      for (final element in blocks) {
        if (element.localName == 'img' && _hasIndexedBlockAncestor(element)) {
          continue;
        }
        final text = _elementText(element);
        if (text.isEmpty) continue;
        raw.add((text: text, selector: _selector(element)));
      }
      if (raw.isEmpty) continue;
      final paragraphs = <IndexedParagraph>[];
      for (var ordinal = 0; ordinal < raw.length; ordinal++) {
        final block = raw[ordinal];
        final digest = sha256
            .convert(
              utf8.encode(
                '$bookHash\n${item.href}\n${block.selector}\n'
                '${block.text.substring(0, block.text.length.clamp(0, 96))}',
              ),
            )
            .toString();
        paragraphs.add(
          IndexedParagraph(
            id: digest.substring(0, 24),
            text: block.text,
            cssSelector: block.selector,
            ordinal: ordinal,
            progression: raw.length == 1 ? 1 : ordinal / (raw.length - 1),
          ),
        );
      }
      final title = parsed.querySelector('title')?.text.trim();
      chapters.add(
        ChapterTextIndex(
          href: Uri.decodeFull(item.href),
          spineOrdinal: chapters.length,
          title: title == null || title.isEmpty ? null : title,
          language:
              parsed.documentElement?.attributes['lang'] ??
              parsed.documentElement?.attributes['xml:lang'],
          paragraphs: paragraphs,
        ),
      );
    }
    if (chapters.isEmpty) {
      throw const FormatException('No readable spine text could be indexed.');
    }
    return BookTextIndex(bookHash: bookHash, chapters: chapters);
  }

  void _validateArchive(Archive archive) {
    if (archive.length > maxIllustrationArchiveEntries) {
      throw const FormatException('The EPUB contains too many files.');
    }
    var expanded = 0;
    for (final entry in archive.files) {
      _safePath(entry.name);
      if (!entry.isFile) continue;
      expanded += entry.size;
      if (expanded > maxIllustrationExpandedBytes) {
        throw const FormatException('The expanded EPUB is too large.');
      }
      final compressed = entry.rawContent?.length ?? entry.size;
      if (entry.size > 1024 * 1024 &&
          compressed > 0 &&
          entry.size / compressed > 200) {
        throw const FormatException(
          'The EPUB contains a suspiciously compressed file.',
        );
      }
    }
  }

  void _validateDirectory(ZipDirectory directory) {
    if (directory.fileHeaders.length > maxIllustrationArchiveEntries) {
      throw const FormatException('The EPUB contains too many files.');
    }
    var expanded = 0;
    for (final header in directory.fileHeaders) {
      _safePath(header.filename);
      expanded += header.uncompressedSize;
      if (expanded > maxIllustrationExpandedBytes) {
        throw const FormatException('The expanded EPUB is too large.');
      }
      if (header.uncompressedSize > 1024 * 1024 &&
          header.compressedSize > 0 &&
          header.uncompressedSize / header.compressedSize > 200) {
        throw const FormatException(
          'The EPUB contains a suspiciously compressed file.',
        );
      }
    }
  }

  ArchiveFile _required(Map<String, ArchiveFile> files, String path) {
    final entry = files[path];
    if (entry == null) throw FormatException('Missing EPUB resource: $path');
    return entry;
  }

  String _decode(ArchiveFile entry) {
    if (entry.size > 20 * 1024 * 1024) {
      throw const FormatException('An EPUB markup file is too large.');
    }
    return utf8.decode(entry.content, allowMalformed: false);
  }

  String _safePath(String value) {
    final normalized = value.replaceAll('\\', '/');
    if (normalized.startsWith('/') ||
        Uri.tryParse(normalized)?.hasScheme == true) {
      throw const FormatException('The EPUB contains an unsafe file path.');
    }
    final segments = <String>[];
    for (final segment in normalized.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (segments.isEmpty) {
          throw const FormatException('The EPUB contains path traversal.');
        }
        segments.removeLast();
      } else {
        segments.add(segment);
      }
    }
    return segments.join('/');
  }

  String _resolvePath(String directory, String href) =>
      _safePath(Uri.decodeFull('$directory${href.split('#').first}'));

  void _removeUnsafeAndHiddenContent(dom.Document document) {
    for (final element in document.querySelectorAll(
      'script,style,noscript,template,nav,[hidden],[aria-hidden="true"]',
    )) {
      element.remove();
    }
  }

  String _elementText(dom.Element element) {
    final parts = <String>[element.text];
    if (element.localName == 'img') {
      final alt = element.attributes['alt']?.trim();
      if (alt != null && alt.isNotEmpty) parts.add(alt);
    }
    for (final image in element.querySelectorAll('img')) {
      final alt = image.attributes['alt']?.trim();
      if (alt != null && alt.isNotEmpty) parts.add(alt);
    }
    return parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  bool _hasIndexedBlockAncestor(dom.Element element) {
    const blockNames = {
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'p',
      'blockquote',
      'li',
      'figcaption',
      'pre',
    };
    dom.Element? ancestor = element.parent;
    while (ancestor != null) {
      if (blockNames.contains(ancestor.localName)) return true;
      ancestor = ancestor.parent;
    }
    return false;
  }

  String _selector(dom.Element element) {
    final parts = <String>[];
    dom.Element? current = element;
    while (current != null && current.localName != 'html') {
      final name = current.localName ?? 'div';
      final parent = current.parent;
      if (parent == null) {
        parts.add(name);
        break;
      }
      final siblings = parent.children
          .where((sibling) => sibling.localName == current!.localName)
          .toList();
      final position = siblings.indexOf(current) + 1;
      parts.add('$name:nth-of-type($position)');
      current = parent;
    }
    return parts.reversed.join(' > ');
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
