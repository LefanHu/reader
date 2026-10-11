/// Locations of the normalized sidecar files inside one book directory.
abstract final class NormalizedBookFiles {
  static final _sectionId = RegExp(r'^s[0-9]+$');

  /// Path of the immutable document manifest.
  static String document(String bookDirectory) =>
      '$bookDirectory/document.json';

  /// Path of one generated section; other IDs never become filenames.
  static String section(String bookDirectory, String sectionId) {
    if (!_sectionId.hasMatch(sectionId)) {
      throw const FormatException('Invalid section ID.');
    }
    return '$bookDirectory/text/$sectionId.json';
  }
}
