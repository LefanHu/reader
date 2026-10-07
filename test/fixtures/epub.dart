import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Minimal EPUB with RTL prose and nested navigation shared by parser and native tests.
/// Optional overrides exercise import trust boundaries without external files.
Uint8List epubFixture({
  String? body,
  String extra = '',
  String? metadata,
  String manifestExtra = '',
  String? navigation,
}) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OPS/book.opf',
        '''<package><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Novel</dc:title><dc:creator>Writer</dc:creator><dc:language>ar</dc:language><dc:identifier>test-id</dc:identifier>${metadata ?? ''}</metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>$manifestExtra</manifest><spine><itemref idref="one"/></spine></package>''',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OPS/one.xhtml',
        '<html dir="rtl"><head><title>Chapter One</title></head><body>${body ?? '<h1 id="chapter">الفصل الأول</h1><p id="passage">مرحبا بالعالم<br/>第二行</p>'}</body></html>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OPS/nav.xhtml',
        navigation ?? '<html><body><nav epub:type="toc"><ol><li><a href="one.xhtml#chapter">Chapter</a><ol><li><a href="one.xhtml#passage">Passage</a></li></ol></li></ol></nav></body></html>',
      ),
    );
  if (extra.isNotEmpty) archive.addFile(ArchiveFile.string(extra, 'unsafe'));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
