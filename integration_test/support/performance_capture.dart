import 'package:vm_service/vm_service.dart';

/// Consumes a phase-owned VM snapshot before JSON serialization. The VM can
/// return its entire symbol cache per phase; retain only functions referenced
/// by samples and remap stack indices without dropping any sample or stack frame.
/// Callers must not reuse the original function indices after this mutation.
void compactCpuSamples(CpuSamples capture) {
  final functions = capture.functions!;
  final samples = capture.samples!;
  final used = <int>{for (final sample in samples) ...sample.stack!}.toList()
    ..sort();
  final remap = {
    for (var index = 0; index < used.length; index++) used[index]: index,
  };
  capture.functions = [for (final index in used) functions[index]];
  for (final sample in samples) {
    sample.stack = [for (final index in sample.stack!) remap[index]!];
  }
}
