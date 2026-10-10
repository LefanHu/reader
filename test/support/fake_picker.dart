import 'package:reader/importing/book_picker.dart';
import 'package:reader/importing/import_candidate.dart';

/// Deterministic picker whose selected files are supplied by each test.
class FakePicker implements BookPicker {
  FakePicker([this.files = const []]);
  List<ImportCandidate> files;
  @override
  Future<List<ImportCandidate>> pick() async => files;
}
