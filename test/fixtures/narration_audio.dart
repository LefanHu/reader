// Fake boundary behavior is documented at each owning type.
// ignore_for_file: public_member_api_docs
import 'dart:typed_data';

/// Valid 24 kHz mono PCM WAV; native scenarios can use real offline audio.
Uint8List testWav({int samples = 24000}) {
  final bytes = Uint8List(44 + samples * 2);
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  bytes.setRange(8, 16, 'WAVEfmt '.codeUnits);
  bytes.setRange(36, 40, 'data'.codeUnits);
  final data = ByteData.sublistView(bytes);
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 24000, Endian.little);
  data.setUint32(28, 48000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, samples * 2, Endian.little);
  return bytes;
}
