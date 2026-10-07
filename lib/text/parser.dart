import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

import 'document.dart';

/// Source and archive bounds enforced before untrusted content is expanded.
const maxBookBytes = 100 * 1024 * 1024;

/// Total expanded archive budget, including resources never rendered.
const maxExpandedBytes = 300 * 1024 * 1024;

/// Maximum archive directory size accepted by the importer.
const maxArchiveEntries = 10000;

/// Each normalized section fits the server's chapter payload limits.
const maxSectionCharacters = 400000;

/// Server paragraph limit, measured in UTF-16 code units.
const maxBlockCharacters = 20000;

/// Isolate-safe parsed import; sections are persisted separately at commit.
class ParsedTextBook {
  /// The cover is local archive data and never fetched over the network.
  const ParsedTextBook(
    this.document,
    this.sections, {
    this.cover,
    this.coverExtension = 'jpg',
  });

  /// Small immutable metadata manifest.
  final TextDocument document;

  /// Normalized text ready for per-section persistence.
  final List<TextSection> sections;

  /// Optional bounded local cover bytes.
  final Uint8List? cover;

  /// Extension chosen from the declared cover MIME type.
  final String coverExtension;
}

/// Pure parsing boundary suitable for execution in a worker isolate.
ParsedTextBook parseTextBook(Uint8List bytes, String name, String hash) {
  if (bytes.length > maxBookBytes) {
    throw const FormatException('The file is larger than 100 MB.');
  }
  final fallback = name.replaceFirst(
    RegExp(r'\.(epub|txt)$', caseSensitive: false),
    '',
  );
  if (name.toLowerCase().endsWith('.txt')) {
    final text = _decodeText(bytes)
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final builder = _Builder(hash);
    for (final part in text.split('\f')) {
      final blocks = part
          .split(RegExp(r'\n[ \t]*\n+'))
          .where((p) => p.trim().isNotEmpty)
          .map((p) => TextBlock(id: '', text: p.trim()))
          .toList();
      builder.add(
        blocks,
        title: 'Section ${builder.sections.length + 1}',
        source: 'txt:${builder.sections.length}',
      );
    }
    return builder.finish(fallback, const []);
  }
  if (!name.toLowerCase().endsWith('.epub')) {
    throw const FormatException('Only EPUB and TXT files are supported.');
  }
  return _parseEpub(bytes, fallback, hash);
}

String _decodeText(Uint8List bytes) {
  if (bytes.length >= 4 &&
      ((bytes[0] == 0xff &&
              bytes[1] == 0xfe &&
              bytes[2] == 0 &&
              bytes[3] == 0) ||
          (bytes[0] == 0 &&
              bytes[1] == 0 &&
              bytes[2] == 0xfe &&
              bytes[3] == 0xff))) {
    throw const FormatException(
      'Convert this TXT file to UTF-8 or BOM-marked UTF-16.',
    );
  }
  try {
    if (bytes.length >= 2 &&
        ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
            (bytes[0] == 0xfe && bytes[1] == 0xff))) {
      if (bytes.length.isOdd) {
        throw const FormatException('Incomplete UTF-16 character.');
      }
      final little = bytes[0] == 0xff;
      final units = <int>[];
      for (var i = 2; i < bytes.length; i += 2) {
        units.add(
          little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
        );
      }
      for (var i = 0; i < units.length; i++) {
        final unit = units[i];
        if (unit >= 0xd800 && unit <= 0xdbff) {
          if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
            throw const FormatException('Unpaired UTF-16 surrogate.');
          }
        } else if (unit >= 0xdc00 && unit <= 0xdfff) {
          throw const FormatException('Unpaired UTF-16 surrogate.');
        }
      }
      return String.fromCharCodes(units);
    }
    final start =
        bytes.length >= 3 &&
            bytes[0] == 0xef &&
            bytes[1] == 0xbb &&
            bytes[2] == 0xbf
        ? 3
        : 0;
    final text = utf8.decode(bytes.sublist(start));
    if (text.contains('\u0000')) {
      throw const FormatException('Unmarked UTF-16 is unsupported.');
    }
    return text;
  } on FormatException {
    throw const FormatException(
      'Invalid TXT encoding. Use UTF-8 or BOM-marked UTF-16.',
    );
  }
}

String _safePath(String path) {
  final normalized = path.replaceAll('\\', '/');
  if (normalized.startsWith('/') ||
      Uri.tryParse(normalized)?.hasScheme == true) {
    throw const FormatException('Unsafe EPUB resource path.');
  }
  final parts = <String>[];
  for (final part in normalized.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isEmpty) {
        throw const FormatException('EPUB path traversal is not allowed.');
      }
      parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.join('/');
}

String _resolve(String base, String href) {
  if (href.startsWith('//') || Uri.tryParse(href)?.hasScheme == true) {
    throw const FormatException('Remote EPUB resources are not supported.');
  }
  final dir = base.contains('/')
      ? base.substring(0, base.lastIndexOf('/') + 1)
      : '';
  return _safePath('$dir${Uri.decodeComponent(href.split('#').first)}');
}

ParsedTextBook _parseEpub(Uint8List bytes, String fallback, String hash) {
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  if (directory.fileHeaders.length > maxArchiveEntries) {
    throw const FormatException('The EPUB contains too many files.');
  }
  var expanded = 0;
  final names = <String>{};
  for (final header in directory.fileHeaders) {
    final path = _safePath(header.filename);
    if (!names.add(path)) {
      throw const FormatException('Duplicate EPUB resource paths.');
    }
    expanded += header.uncompressedSize;
    if (expanded > maxExpandedBytes ||
        (header.uncompressedSize > 1024 * 1024 &&
            (header.compressedSize == 0 ||
                header.uncompressedSize / header.compressedSize > 200))) {
      throw const FormatException(
        'The expanded EPUB is too large or suspiciously compressed.',
      );
    }
    if (path.toLowerCase().endsWith('.js')) {
      throw const FormatException('Scripted EPUB content is not supported.');
    }
  }
  final archive = ZipDecoder().decodeBytes(bytes, verify: true);
  final files = {
    for (final file in archive.files.where((item) => item.isFile))
      _safePath(file.name): file,
  };
  String read(String path) {
    final file = files[path];
    if (file == null) throw FormatException('Missing EPUB resource: $path');
    if (file.size > 20 * 1024 * 1024) {
      throw const FormatException('EPUB markup is too large.');
    }
    return utf8.decode(file.content);
  }

  if (files.containsKey('META-INF/encryption.xml') &&
      XmlDocument.parse(read('META-INF/encryption.xml')).descendants
          .whereType<XmlElement>()
          .any((e) => e.localName == 'EncryptedData')) {
    throw const FormatException(
      'DRM-protected or encrypted EPUBs are not supported.',
    );
  }
  if (files.containsKey('META-INF/license.lcpl')) {
    throw const FormatException('DRM-protected EPUBs are not supported.');
  }
  final container = XmlDocument.parse(read('META-INF/container.xml'));
  final rootfile = container.descendants
      .whereType<XmlElement>()
      .where((e) => e.localName == 'rootfile')
      .firstOrNull;
  final opfPath = _safePath(rootfile?.getAttribute('full-path') ?? '');
  final opf = XmlDocument.parse(read(opfPath));
  final elements = opf.descendants.whereType<XmlElement>().toList();
  String? metadata(String tag) => elements
      .where((e) => e.localName == tag)
      .map((e) => e.innerText.trim())
      .where((value) => value.isNotEmpty)
      .firstOrNull;
  if (elements.any(
    (e) =>
        (e.getAttribute('property') == 'rendition:layout' &&
            e.innerText.trim() == 'pre-paginated') ||
        (e.getAttribute('name') == 'fixed-layout' &&
            e.getAttribute('content') == 'true'),
  )) {
    throw const FormatException('Fixed-layout EPUBs are not supported.');
  }
  final manifest = <String, XmlElement>{};
  for (final item in elements.where((e) => e.localName == 'item')) {
    final properties = (item.getAttribute('properties') ?? '').split(
      RegExp(r'\s+'),
    );
    if (properties.contains('scripted') ||
        item.getAttribute('media-type') == 'application/javascript') {
      throw const FormatException('Scripted EPUB content is not supported.');
    }
    if (properties.contains('remote-resources')) {
      throw const FormatException('Remote EPUB resources are not supported.');
    }
    _resolve(opfPath, item.getAttribute('href') ?? '');
    manifest[item.getAttribute('id') ?? ''] = item;
  }
  if (elements.any(
    (e) =>
        e.localName == 'itemref' &&
        (e.getAttribute('properties') ?? '').contains(
          'rendition:layout-pre-paginated',
        ),
  )) {
    throw const FormatException('Fixed-layout EPUBs are not supported.');
  }
  // Inspect all declared markup, not just the linear spine. Scripts and remote
  // loads in navigation or unused resources violate the same import policy.
  for (final item in manifest.values) {
    final mime = item.getAttribute('media-type');
    final path = _resolve(opfPath, item.getAttribute('href')!);
    if ({
      'application/xhtml+xml',
      'text/html',
      'image/svg+xml',
    }.contains(mime)) {
      _validateMarkup(html.parse(read(path)));
    } else if (mime == 'text/css' && _remoteCss(read(path))) {
      throw const FormatException('Remote EPUB resources are not supported.');
    }
  }
  final builder = _Builder(hash);
  final targets = <String, TextPosition>{};
  final language = metadata('language');
  for (final ref in elements.where((e) => e.localName == 'itemref')) {
    if (ref.getAttribute('linear') == 'no') continue;
    final item = manifest[ref.getAttribute('idref')];
    if (item == null) {
      throw const FormatException('Missing EPUB spine resource.');
    }
    if (!{
      'application/xhtml+xml',
      'text/html',
    }.contains(item.getAttribute('media-type'))) {
      continue;
    }
    final path = _resolve(opfPath, item.getAttribute('href')!);
    // Every declared markup resource already passed the manifest policy check.
    final parsed = html.parse(read(path));
    final blocks = <TextBlock>[];
    final sourceIds = <String, int>{};
    final buffer = StringBuffer();
    String kind = 'paragraph';
    String? direction;
    void flush() {
      final value = kind == 'pre'
          ? buffer.toString().trim()
          : buffer
                .toString()
                .replaceAll(RegExp(r'[ \t]+'), ' ')
                .replaceAll(RegExp(r' *\n *'), '\n')
                .trim();
      buffer.clear();
      if (value.isNotEmpty) {
        blocks.add(
          TextBlock(id: '', text: value, kind: kind, direction: direction),
        );
      }
    }

    const blockTags = {
      'p',
      'div',
      'section',
      'article',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'li',
      'blockquote',
      'pre',
      'figcaption',
      'dt',
      'dd',
    };
    void walk(dom.Node node, String? inherited) {
      if (node is dom.Text) {
        buffer.write(
          kind == 'pre' ? node.text : node.text.replaceAll(RegExp(r'\s+'), ' '),
        );
        return;
      }
      if (node is! dom.Element) return;
      final tag = node.localName;
      if ({
            'script',
            'style',
            'noscript',
            'template',
            'nav',
            'img',
            'svg',
            'head',
          }.contains(tag) ||
          node.attributes.containsKey('hidden') ||
          node.attributes['aria-hidden'] == 'true' ||
          RegExp(
            r'display\s*:\s*none|visibility\s*:\s*hidden',
            caseSensitive: false,
          ).hasMatch(node.attributes['style'] ?? '')) {
        return;
      }
      final dir = node.attributes['dir'] == 'auto'
          ? null
          : {'rtl', 'ltr'}.contains(node.attributes['dir'])
          ? node.attributes['dir']
          : inherited;
      final isBlock = blockTags.contains(tag);
      final previousKind = kind;
      final previousDirection = direction;
      if (isBlock) {
        flush();
        kind = tag != null && RegExp(r'^h[1-6]$').hasMatch(tag)
            ? 'heading'
            : tag == 'li'
            ? 'list'
            : tag == 'blockquote'
            ? 'quote'
            : tag == 'pre'
            ? 'pre'
            : {'quote', 'list', 'pre'}.contains(previousKind)
            ? previousKind
            : 'paragraph';
        direction = dir;
      }
      if (node.id.isNotEmpty) {
        sourceIds.putIfAbsent(node.id, () => blocks.length);
      }
      if (tag == 'br') {
        buffer.write('\n');
      } else {
        for (final child in node.nodes) {
          walk(child, dir);
        }
      }
      if (isBlock) {
        flush();
        kind = previousKind;
        direction = previousDirection;
      }
    }

    walk(parsed.body!, parsed.documentElement?.attributes['dir']);
    flush();
    final firstSection = builder.sections.length;
    builder.add(
      blocks,
      title: parsed.querySelector('title')?.text.trim().isNotEmpty == true
          ? parsed.querySelector('title')!.text.trim()
          : 'Section ${firstSection + 1}',
      source: path,
      language:
          parsed.documentElement?.attributes['lang'] ??
          parsed.documentElement?.attributes['xml:lang'] ??
          language,
      sourceIds: sourceIds,
      targets: targets,
    );
  }
  Uint8List? cover;
  var coverExtension = 'jpg';
  final coverId = elements
      .where((e) => e.localName == 'meta' && e.getAttribute('name') == 'cover')
      .firstOrNull
      ?.getAttribute('content');
  final coverItem = manifest.values
      .where(
        (e) =>
            (e.getAttribute('properties') ?? '')
                .split(' ')
                .contains('cover-image') ||
            e.getAttribute('id') == coverId,
      )
      .firstOrNull;
  if (coverItem != null &&
      {
        'image/png',
        'image/jpeg',
      }.contains(coverItem.getAttribute('media-type'))) {
    final file = files[_resolve(opfPath, coverItem.getAttribute('href')!)];
    if (file != null && file.size <= 10 * 1024 * 1024) {
      cover = Uint8List.fromList(file.content);
      coverExtension = coverItem.getAttribute('media-type') == 'image/png'
          ? 'png'
          : 'jpg';
    }
  }
  TextPosition? target(String base, String href) {
    try {
      final path = _resolve(base, href);
      final fragment = href.contains('#')
          ? Uri.decodeComponent(href.substring(href.indexOf('#') + 1))
          : '';
      return targets['$path#$fragment'] ?? targets[path];
    } on FormatException {
      return null;
    }
  }

  var contents = <TextContentsEntry>[];
  final nav = manifest.values
      .where(
        (e) => (e.getAttribute('properties') ?? '').split(' ').contains('nav'),
      )
      .firstOrNull;
  if (nav != null) {
    final path = _resolve(opfPath, nav.getAttribute('href')!);
    final parsed = html.parse(read(path));
    final toc =
        parsed
            .querySelectorAll('nav')
            .where(
              (e) => (e.attributes['epub:type'] ?? e.attributes['type'] ?? '')
                  .split(' ')
                  .contains('toc'),
            )
            .firstOrNull ??
        parsed.querySelector('nav');
    List<TextContentsEntry> entries(dom.Element? list) => list == null
        ? []
        : list.children.where((e) => e.localName == 'li').map((li) {
            final label = li.children
                .where((e) => e.localName == 'a' || e.localName == 'span')
                .firstOrNull;
            final href = label?.attributes['href'];
            return TextContentsEntry(
              title: label?.text.trim() ?? 'Untitled section',
              position: href == null ? null : target(path, href),
              children: entries(
                li.children.where((e) => e.localName == 'ol').firstOrNull,
              ),
            );
          }).toList();
    contents = entries(toc?.querySelector('ol'));
  } else {
    final ncx = manifest.values
        .where(
          (e) => e.getAttribute('media-type') == 'application/x-dtbncx+xml',
        )
        .firstOrNull;
    if (ncx != null) {
      final path = _resolve(opfPath, ncx.getAttribute('href')!);
      final parsed = XmlDocument.parse(read(path));
      List<TextContentsEntry> entries(XmlElement parent) => parent.childElements
          .where((e) => e.localName == 'navPoint')
          .map((point) {
            final label = point.childElements
                .where((e) => e.localName == 'navLabel')
                .firstOrNull
                ?.innerText
                .trim();
            final href = point.childElements
                .where((e) => e.localName == 'content')
                .firstOrNull
                ?.getAttribute('src');
            return TextContentsEntry(
              title: label ?? 'Untitled section',
              position: href == null ? null : target(path, href),
              children: entries(point),
            );
          })
          .toList();
      final map = parsed.descendants
          .whereType<XmlElement>()
          .where((e) => e.localName == 'navMap')
          .firstOrNull;
      if (map != null) contents = entries(map);
    }
  }
  return builder.finish(
    metadata('title') ?? fallback,
    elements
        .where((e) => e.localName == 'creator')
        .map((e) => e.innerText.trim())
        .where((value) => value.isNotEmpty)
        .toList(),
    language: language,
    identifier: metadata('identifier'),
    contents: contents,
    cover: cover,
    coverExtension: coverExtension,
  );
}

bool _remoteCss(String value) => RegExp(
  r"""(?:url\s*\(\s*["']?|@import\s*["'])(?:https?:)?//""",
  caseSensitive: false,
).hasMatch(value);

void _validateMarkup(dom.Document parsed) {
  // No markup is ever executed, and no resource is ever fetched by the reader.
  // Reject unsupported source declarations consistently before normalization.
  if (parsed.querySelectorAll('script,iframe,object,embed').isNotEmpty ||
      parsed
          .querySelectorAll('*')
          .any(
            (element) => element.attributes.keys.any(
              (key) => key.toString().toLowerCase().startsWith('on'),
            ),
          )) {
    throw const FormatException('Scripted EPUB content is not supported.');
  }
  for (final element in parsed.querySelectorAll('*')) {
    for (final attribute in [
      'src',
      'srcset',
      'poster',
      if (element.localName != 'a') 'href',
    ]) {
      final value = element.attributes[attribute];
      if (value != null &&
          RegExp(r'(?:https?:)?//', caseSensitive: false).hasMatch(value)) {
        throw const FormatException('Remote EPUB resources are not supported.');
      }
    }
    if (_remoteCss(element.attributes['style'] ?? '') ||
        (element.localName == 'style' && _remoteCss(element.text))) {
      throw const FormatException('Remote EPUB resources are not supported.');
    }
  }
}

class _Builder {
  _Builder(this.hash);
  final String hash;
  final sections = <TextSection>[];
  final summaries = <SectionSummary>[];
  void add(
    List<TextBlock> sourceBlocks, {
    required String title,
    required String source,
    String? language,
    Map<String, int> sourceIds = const {},
    Map<String, TextPosition>? targets,
  }) {
    var blocks = <TextBlock>[];
    var length = 0;
    void commit() {
      if (blocks.isEmpty) return;
      final id = 's${sections.length}';
      sections.add(TextSection(id: id, blocks: blocks));
      summaries.add(
        SectionSummary(
          id: id,
          title: summaries.any((item) => item.source == source)
              ? '$title (continued)'
              : title,
          source: source,
          length: length,
          language: language,
        ),
      );
      blocks = [];
      length = 0;
    }

    for (var ordinal = 0; ordinal < sourceBlocks.length; ordinal++) {
      final block = sourceBlocks[ordinal];
      final pieces = <String>[];
      var buffer = StringBuffer();
      for (final cluster in block.text.characters) {
        if (cluster.length > maxBlockCharacters) {
          throw const FormatException(
            'A single text character exceeds the paragraph limit.',
          );
        }
        if (buffer.length + cluster.length > maxBlockCharacters) {
          pieces.add(buffer.toString());
          buffer = StringBuffer();
        }
        buffer.write(cluster);
      }
      if (buffer.isNotEmpty) pieces.add(buffer.toString());
      for (var piece = 0; piece < pieces.length; piece++) {
        final text = pieces[piece];
        if (length + text.length > maxSectionCharacters ||
            blocks.length >= 2000) {
          commit();
        }
        final sectionId = 's${sections.length}';
        final id = sha256
            .convert(utf8.encode('$hash:$source:$ordinal:$piece'))
            .toString()
            .substring(0, 24);
        final position = TextPosition(sectionId: sectionId, blockId: id);
        targets?.putIfAbsent(source, () => position);
        if (piece == 0) {
          for (final entry in sourceIds.entries.where(
            (entry) => entry.value == ordinal,
          )) {
            targets?.putIfAbsent('$source#${entry.key}', () => position);
          }
        }
        blocks.add(
          TextBlock(
            id: id,
            text: text,
            kind: block.kind,
            direction: block.direction,
            sourceId: piece == 0
                ? sourceIds.entries
                      .where((entry) => entry.value == ordinal)
                      .firstOrNull
                      ?.key
                : null,
          ),
        );
        length += text.length;
      }
    }
    commit();
    if (sections.length > 10000) {
      throw const FormatException('The book contains too many sections.');
    }
  }

  ParsedTextBook finish(
    String title,
    List<String> authors, {
    String? language,
    String? identifier,
    List<TextContentsEntry>? contents,
    Uint8List? cover,
    String coverExtension = 'jpg',
  }) {
    if (sections.isEmpty) {
      throw const FormatException('This book has no readable text.');
    }
    return ParsedTextBook(
      TextDocument(
        title: title,
        authors: authors,
        sections: summaries,
        contents: contents?.isNotEmpty == true
            ? contents!
            : [
                for (var i = 0; i < sections.length; i++)
                  TextContentsEntry(
                    title: summaries[i].title,
                    position: sections[i].start,
                  ),
              ],
        language: language,
        identifier: identifier,
      ),
      sections,
      cover: cover,
      coverExtension: coverExtension,
    );
  }
}
