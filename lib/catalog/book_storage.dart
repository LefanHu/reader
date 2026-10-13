import 'dart:io';

import '../hex_identifiers.dart';
import 'catalog_book.dart';

/// Returns `<root>/books/<hash>` only when it is a real, app-owned directory
/// (no symbolic links on the way) that directly contains [book]'s file path.
Directory? ownedBookDirectory(Directory root, CatalogBook book) {
  if (!sha256Hex.hasMatch(book.hash)) return null;
  final base = root.absolute.path;
  final expected = '$base/books/${book.hash}';
  for (final path in [base, '$base/books', expected]) {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
  }
  if (File(book.path).parent.absolute.path != expected) return null;
  return Directory(expected);
}

/// Returns the owned per-book feature directory `<book dir>/<name>`, which may
/// not exist yet.
///
/// Throws [FormatException] when the book is outside owned storage, its file
/// is not a regular file, or the feature path exists as a non-directory.
Directory featureDirectory(Directory root, CatalogBook book, String name) {
  final owned = ownedBookDirectory(root, book);
  if (owned == null ||
      FileSystemEntity.typeSync(book.path, followLinks: false) !=
          FileSystemEntityType.file) {
    throw const FormatException('Book storage is outside owned storage.');
  }
  final directory = Directory('${owned.path}/$name');
  final kind = FileSystemEntity.typeSync(directory.path, followLinks: false);
  if (kind != FileSystemEntityType.notFound &&
      kind != FileSystemEntityType.directory) {
    throw const FormatException('Book feature storage cannot be a link.');
  }
  return directory;
}
