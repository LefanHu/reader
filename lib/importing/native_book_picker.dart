import 'package:file_picker/file_picker.dart';

import 'book_picker.dart';
import 'import_candidate.dart';

/// Platform document picker supporting multiple text-focused book imports.
class NativeBookPicker implements BookPicker {
  @override
  Future<List<ImportCandidate>> pick() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Import books',
      type: FileType.custom,
      allowedExtensions: const ['epub', 'txt'],
    );
    return [
      for (final file in files)
        ImportCandidate(
          name: file.name,
          size: await file.length() ?? -1,
          readBytes: file.readAsBytes,
        ),
    ];
  }
}
