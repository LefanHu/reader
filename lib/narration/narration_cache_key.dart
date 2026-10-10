import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../catalog/catalog_book.dart';
import '../text/narration_chunk.dart';
import 'narration_manifest.dart';

/// Cache identity includes owner, source, exact anchors/prose, model and settings.
String narrationCacheKey(
  CatalogBook book,
  NarrationManifest manifest,
  NarrationChunk chunk,
) => narrationFingerprintKey(
  jsonEncode({
    'account': manifest.account,
    'book': book.hash,
    'document': chunk.start.version,
    'chunkVersion': narrationChunkVersion,
    'chunk': chunk.id,
    'digest': chunk.digest,
    'model': 'gpt-realtime-2.1-mini',
    'voice': manifest.voice,
    'format': 'pcm-24000-mono-v1',
  }),
);

/// Hashes canonical generation settings without leaking account IDs in filenames.
String narrationFingerprintKey(String value) =>
    sha256.convert(utf8.encode(value)).toString();
