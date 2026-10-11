import 'dart:io';
import 'dart:typed_data';

/// Maximum complete WAV size accepted by either narration generation engine.
const maxNarrationAudioBytes = 32 * 1024 * 1024;

/// Checks RIFF/PCM structure without decoding or copying the audio payload.
///
/// Both engines publish PCM16 WAV. Unknown RIFF chunks are skipped, so native
/// files with format extensions or padding do not need the cloud's 44-byte
/// header. A nonempty, aligned data chunk and consistent format are required.
Future<Duration> validateNarrationWav(File file) async {
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const FormatException('Narration WAV must be a regular file.');
  }
  final handle = await file.open();
  try {
    final length = await handle.length();
    if (length < 44 || length > maxNarrationAudioBytes) {
      throw const FormatException('Invalid narration WAV size.');
    }
    final header = await handle.read(12);
    if (!_tag(header, 0, 'RIFF') ||
        !_tag(header, 8, 'WAVE') ||
        ByteData.sublistView(header).getUint32(4, Endian.little) + 8 !=
            length) {
      throw const FormatException('Invalid narration WAV header.');
    }
    var offset = 12;
    var sampleRate = 0;
    var bytesPerFrame = 0;
    var frames = 0;
    while (offset < length) {
      if (offset + 8 > length) {
        throw const FormatException('Truncated narration WAV chunk.');
      }
      await handle.setPosition(offset);
      final chunk = await handle.read(8);
      final size = ByteData.sublistView(chunk).getUint32(4, Endian.little);
      final end = offset + 8 + size;
      final paddedEnd = end + (size & 1);
      if (paddedEnd > length) {
        throw const FormatException('Truncated narration WAV payload.');
      }
      if (_tag(chunk, 0, 'fmt ')) {
        if (sampleRate != 0 || size < 16) {
          throw const FormatException('Invalid narration WAV format.');
        }
        final format = ByteData.sublistView(await handle.read(16));
        final channels = format.getUint16(2, Endian.little);
        sampleRate = format.getUint32(4, Endian.little);
        bytesPerFrame = format.getUint16(12, Endian.little);
        var pcm16 = format.getUint16(0, Endian.little) == 1;
        if (format.getUint16(0, Endian.little) == 0xfffe && size >= 40) {
          // WAVE_FORMAT_EXTENSIBLE is PCM only with the integer PCM subtype;
          // float and other codecs are not made playable by a matching header.
          final extension = ByteData.sublistView(await handle.read(24));
          pcm16 =
              extension.getUint16(0, Endian.little) >= 22 &&
              extension.getUint16(2, Endian.little) == 16 &&
              extension.getUint32(8, Endian.little) == 1 &&
              extension.getUint32(12, Endian.little) == 0x00100000 &&
              extension.getUint32(16, Endian.little) == 0xaa000080 &&
              extension.getUint32(20, Endian.little) == 0x719b3800;
        }
        if (!pcm16 ||
            channels == 0 ||
            sampleRate == 0 ||
            format.getUint16(14, Endian.little) != 16 ||
            bytesPerFrame != channels * 2 ||
            format.getUint32(8, Endian.little) != sampleRate * bytesPerFrame) {
          throw const FormatException('Unsupported narration PCM layout.');
        }
      } else if (_tag(chunk, 0, 'data')) {
        if (sampleRate == 0 ||
            frames != 0 ||
            size == 0 ||
            size % bytesPerFrame != 0) {
          throw const FormatException('Invalid narration PCM payload.');
        }
        frames = size ~/ bytesPerFrame;
      }
      offset = paddedEnd;
    }
    if (frames == 0) {
      throw const FormatException('Narration WAV has no audio.');
    }
    return Duration(microseconds: (frames * 1000000 / sampleRate).round());
  } finally {
    await handle.close();
  }
}

bool _tag(Uint8List bytes, int offset, String value) {
  if (bytes.length < offset + value.length) return false;
  for (var index = 0; index < value.length; index++) {
    if (bytes[offset + index] != value.codeUnitAt(index)) return false;
  }
  return true;
}
