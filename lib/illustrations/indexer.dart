import 'book_text_index.dart';

/// Derives illustration prose from the same immutable text the viewport draws.
abstract interface class TextIndexer {
  /// Reads normalized sidecars, never reparsing source EPUB or TXT content.
  Future<BookTextIndex> index({
    required String sourcePath,
    required String bookHash,
  });
}
