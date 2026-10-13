import '../text/document.dart';
import '../text/document_store.dart';
import '../text/narration_playback_unit.dart';
import '../text/text_position.dart';
import '../text/text_section.dart';
import 'source.dart';

/// A narration session's place in one book: the loaded section, its playback
/// units and the next unit to play.
///
/// Units come only from the source's segmentation of the normalized section,
/// so chunk identities and complete start/end positions match the reader.
/// Holds no fence of its own: every load takes the session's `isCurrent`
/// check, and a stale load leaves the session's cursor untouched.
class NarrationCursor {
  NarrationCursor._(
    this._documents,
    this._source,
    this._bookPath,
    this.document,
    this._section,
    this._units,
  );

  /// Loads the section containing [anchor] and its units starting there; the
  /// first section for an absent or unknown anchor.
  ///
  /// An [exact] anchor (an explicit Read from here) must name a known section
  /// and resolve unchanged, else this throws [ArgumentError]. Returns null when
  /// [isCurrent] fails after a load.
  static Future<NarrationCursor?> open({
    required TextDocumentStore documents,
    required NarrationSource source,
    required String bookPath,
    required TextDocument document,
    required TextPosition? anchor,
    required bool exact,
    required bool Function() isCurrent,
  }) async {
    final ordinal = document.ordinalOf(anchor?.sectionId);
    if (exact && ordinal < 0) {
      throw ArgumentError.value(anchor, 'start', 'Unknown narration section.');
    }
    final section = await documents.loadSection(
      bookPath,
      document.sections[ordinal < 0 ? 0 : ordinal].id,
    );
    if (!isCurrent()) return null;
    if (exact && section.resolve(anchor!) != anchor) {
      throw ArgumentError.value(anchor, 'start', 'Invalid narration anchor.');
    }
    final units = await source.units(
      section,
      from: anchor,
      language: document.language,
    );
    if (!isCurrent()) return null;
    return NarrationCursor._(
      documents,
      source,
      bookPath,
      document,
      section,
      units,
    );
  }

  final TextDocumentStore _documents;
  final NarrationSource _source;
  final String _bookPath;

  /// Immutable manifest of the narrated book.
  final TextDocument document;

  TextSection _section;
  List<NarrationPlaybackUnit> _units;
  int _index = 0;

  /// The next unit to play, or null once the loaded section is exhausted.
  NarrationPlaybackUnit? get current =>
      _index < _units.length ? _units[_index] : null;

  /// The current unit followed by up to `count - 1` buffered ones.
  Iterable<NarrationPlaybackUnit> upcoming(int count) =>
      _units.skip(_index).take(count);

  /// Moves past the current unit after its natural completion.
  void advance() => _index++;

  /// Loads following sections until [current] is available. Returns true when
  /// it is, false at the end of the book, and null when [isCurrent] fails.
  Future<bool?> fill(bool Function() isCurrent) async {
    while (_index >= _units.length) {
      final ordinal = document.ordinalOf(_section.id) + 1;
      if (ordinal >= document.sections.length) return false;
      final section = await _documents.loadSection(
        _bookPath,
        document.sections[ordinal].id,
      );
      if (!isCurrent()) return null;
      final units = await _source.units(section, language: document.language);
      if (!isCurrent()) return null;
      _section = section;
      _units = units;
      _index = 0;
    }
    return true;
  }

  /// Book progress at [position] inside the loaded section.
  double progress(TextPosition position) =>
      document.progress(_section, position);
}
