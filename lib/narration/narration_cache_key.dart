import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../catalog/catalog_book.dart';
import '../text/narration_chunk.dart';
import '../text/narration_range.dart';
import 'narration_manifest.dart';

/// Cache identity includes owner, source, exact anchors/prose, model and settings.
String narrationCacheKey(
  CatalogBook book,
  NarrationManifest manifest,
  NarrationChunk chunk, {
  NarrationRange? sentence,
}) => narrationFingerprintKey(
  jsonEncode(
    manifest.engine == 'openai-realtime'
        ? {
            'account': manifest.account,
            'book': book.hash,
            'chunk': chunk.id,
            'digest': chunk.digest,
            'model': 'gpt-realtime-2.1-mini',
            'voice': manifest.voice,
            'format': 'pcm-24000-mono',
          }
        : {
            'engine': manifest.engine,
            'book': book.hash,
            'start': chunk.start.toJson(),
            'end': chunk.end.toJson(),
            'sentence': sentence?.toJson(),
            'digest': chunk.digest,
            'segmentationPolicy': manifest.segmentationPolicy,
            'voice': manifest.voice,
            'synthesisFingerprint': manifest.synthesisFingerprint,
            'rate': 'AVSpeechUtteranceDefaultSpeechRate',
            'format': 'apple-pcm16-native',
          },
  ),
);

/// Hashes canonical generation settings without leaking account IDs in filenames.
String narrationFingerprintKey(String value) =>
    sha256.convert(utf8.encode(value)).toString();
