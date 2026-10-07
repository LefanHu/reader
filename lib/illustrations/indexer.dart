import '../text/document.dart';
import 'models.dart';

/// Derives illustration prose from the same immutable text the viewport draws.
abstract interface class TextIndexer {
  /// Reads normalized sidecars, never reparsing source EPUB or TXT content.
  Future<BookTextIndex> index({
    required String sourcePath,
    required String bookHash,
  });
}

/// Loads bounded normalized sections and preserves server paragraph mappings.
class DocumentTextIndexer implements TextIndexer {
  /// The store can be injected for tests without filesystem access.
  DocumentTextIndexer({TextDocumentStore? store})
    : store = store ?? TextDocumentStore();

  /// Shared document boundary used by reading and generation.
  final TextDocumentStore store;
  @override
  Future<BookTextIndex> index({
    required String sourcePath,
    required String bookHash,
  }) async {
    final document = await store.load(sourcePath);
    final chapters = <ChapterTextIndex>[];
    for (var ordinal = 0; ordinal < document.sections.length; ordinal++) {
      final summary = document.sections[ordinal];
      final section = await store.loadSection(sourcePath, summary.id);
      chapters.add(
        ChapterTextIndex(
          href: section.id,
          spineOrdinal: ordinal,
          title: summary.title,
          language: summary.language,
          paragraphs: [
            for (var i = 0; i < section.blocks.length; i++)
              IndexedParagraph(
                id: section.blocks[i].id,
                text: section.blocks[i].text,
                cssSelector: '#${section.blocks[i].id}',
                ordinal: i,
                progression: section.blocks.length == 1
                    ? 1
                    : i / (section.blocks.length - 1),
              ),
          ],
        ),
      );
    }
    return BookTextIndex(bookHash: bookHash, chapters: chapters);
  }
}
