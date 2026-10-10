import 'package:reader/illustrations/indexer.dart';
import 'package:reader/illustrations/book_text_index.dart';
import 'package:reader/illustrations/chapter_text_index.dart';
import 'package:reader/illustrations/indexed_paragraph.dart';

/// Stable one-chapter index used unless a test supplies its own indexer.
class FakeTextIndexer implements TextIndexer {
  FakeTextIndexer({this.chapters = _defaultChapters});

  final List<ChapterTextIndex> chapters;

  static const _defaultChapters = [
    ChapterTextIndex(
      href: 's0',
      spineOrdinal: 0,
      title: null,
      paragraphs: [
        IndexedParagraph(
          id: 'paragraph-1',
          text: 'A test paragraph.',
          cssSelector: 'body > p:nth-of-type(1)',
          ordinal: 0,
          progression: 1,
        ),
      ],
    ),
  ];

  @override
  Future<BookTextIndex> index({
    required String sourcePath,
    required String bookHash,
  }) async => BookTextIndex(bookHash: bookHash, chapters: chapters);
}
