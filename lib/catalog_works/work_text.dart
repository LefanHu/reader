import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../text/document_store.dart';

/// Bytes per paragraph fingerprint; all zeros marks a skipped paragraph.
const workFingerprintBytes = 8;

/// Normalized paragraphs shorter than this repeat too often to identify a text.
const _minFingerprintCharacters = 20;

final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// Text that survives formatting differences between files of the same work:
/// lowercase letters and digits only. Final sigma folds to sigma because Dart
/// and JS lowercase it differently. Must stay identical to `normalizeParagraph`
/// in `backend/src/work-text.ts`; `backend/test-fixtures/fingerprints.json`
/// pins both.
String normalizeWorkParagraph(String text) => _letterOrDigit
    .allMatches(text.toLowerCase())
    .map((match) => match[0])
    .join()
    .replaceAll('ς', 'σ');

/// First 8 bytes of SHA-256 over the normalized text, or zeros when it is too
/// short to identify a work.
Uint8List workParagraphFingerprint(String text) {
  final normalized = normalizeWorkParagraph(text);
  if (normalized.runes.length < _minFingerprintCharacters) {
    return Uint8List(workFingerprintBytes);
  }
  return Uint8List.fromList(
    sha256
        .convert(utf8.encode(normalized))
        .bytes
        .sublist(0, workFingerprintBytes),
  );
}

/// A book's per-paragraph fingerprints, built off the UI isolate. They are
/// the only thing about the text that leaves the device: never the text itself.
class WorkText {
  /// Pairs the concatenated fingerprints with the book's section count.
  const WorkText({required this.fingerprints, required this.sectionCount});

  /// Concatenated [workParagraphFingerprint]s of every paragraph (every
  /// normalized block, in reading order across sections).
  final Uint8List fingerprints;

  /// Number of sections, for the shared book registration.
  final int sectionCount;
}

/// Fingerprints every normalized block of the book at [sourcePath].
///
/// With the default disk store the whole pass runs on one background isolate;
/// an injected store runs on the calling isolate, for tests.
Future<WorkText> buildWorkText(
  String sourcePath, {
  TextDocumentStore? documents,
}) => documents == null
    ? Isolate.run(() => _build(sourcePath, InlineTextDocumentStore()))
    : _build(sourcePath, documents);

Future<WorkText> _build(String sourcePath, TextDocumentStore documents) async {
  final document = await documents.load(sourcePath);
  final fingerprints = BytesBuilder(copy: false);
  for (final summary in document.sections) {
    final section = await documents.loadSection(sourcePath, summary.id);
    for (final block in section.blocks) {
      fingerprints.add(workParagraphFingerprint(block.text));
    }
  }
  return WorkText(
    fingerprints: fingerprints.takeBytes(),
    sectionCount: document.sections.length,
  );
}
