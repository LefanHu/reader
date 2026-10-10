// DTO fields mirror the documented REST contract in this file.
// ignore_for_file: public_member_api_docs

import 'dart:typed_data';

/// Released metadata and bytes, returned only after the local spoiler gate.
class UnlockedIllustration {
  const UnlockedIllustration({
    required this.image,
    required this.thumbnail,
    required this.altText,
    required this.caption,
    required this.generationVersion,
  });

  final Uint8List image;
  final Uint8List thumbnail;
  final String altText;
  final String caption;
  final int generationVersion;
}
