/// Controls how normalized text moves through the reader viewport.
enum ReadingMode {
  /// One continuous vertical flow.
  scroll,

  /// Discrete horizontally navigated pages.
  pages,

  /// Discrete pages with an interactive paper curl; persists as `pageFlip`.
  pageFlip,
}
