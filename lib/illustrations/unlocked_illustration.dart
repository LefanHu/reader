// DTO fields mirror the documented REST contract in this file.
// ignore_for_file: public_member_api_docs

import 'dart:typed_data';

/// Released metadata and bytes for a scene whose anchor resolves locally.
class UnlockedIllustration {
  const UnlockedIllustration({
    required this.image,
    required this.thumbnail,
    required this.altText,
    required this.caption,
    required this.generationVersion,
    required this.imageMimeType,
    required this.thumbnailMimeType,
    required this.thumbnailUsesOriginal,
  });

  final Uint8List image;
  final Uint8List thumbnail;
  final String altText;
  final String caption;

  /// Version to commit only after both assets and the local manifest are saved.
  final int generationVersion;

  /// Verified native PNG/JPEG/WebP MIME of the byte-preserved original.
  final String imageMimeType;

  /// Derived WebP MIME, or native original MIME when the preview is aliased.
  final String thumbnailMimeType;

  /// When true, both byte fields refer to the same downloaded original.
  final bool thumbnailUsesOriginal;
}
