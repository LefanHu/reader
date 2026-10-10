import 'dart:typed_data';

/// Lazy source selection so a multi-file import reads one book at a time.
class ImportCandidate {
  /// Picker metadata is checked again after source bytes are read.
  const ImportCandidate({
    required this.name,
    required this.size,
    required this.readBytes,
  });

  /// Original filename, also the TXT title fallback.
  final String name;

  /// Reported byte length, or -1 if unavailable.
  final int size;

  /// Reads the selection while its platform access is still available.
  final Future<Uint8List> Function() readBytes;
}
