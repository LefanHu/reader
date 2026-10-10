import 'import_candidate.dart';

/// Native file selection boundary, replaceable in tests.
abstract interface class BookPicker {
  /// Selects EPUB and TXT files without eagerly reading all selections.
  Future<List<ImportCandidate>> pick();
}
