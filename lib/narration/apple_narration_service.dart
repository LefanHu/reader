import 'dart:io';

import 'package:flutter/services.dart';

import '../text/text_section.dart';
import 'narration_voice.dart';

/// Narrow engine-owned Apple boundary. No account/cloud API or PCM bytes cross
/// this channel. Staging files belong to NarrationStore, not the synthesizer.
class AppleNarrationService {
  /// Uses the engine channel; injection is for deterministic boundary fixtures.
  AppleNarrationService({
    this._channel = const MethodChannel('reader/narration'),
  });

  final MethodChannel _channel;
  var _request = 0;
  List<NarrationVoice> _voices = const [];
  String? _defaultVoice;
  String _fingerprint = '';

  /// Immutable catalog snapshot of ordinary installed voices (no Personal Voice).
  List<NarrationVoice> get voices => _voices;

  /// Namespaced default for the preferred language, or genuine unavailability.
  String? get defaultVoice => _defaultVoice;

  /// Actual OS synthesis build; native timing/cache identity changes with it.
  String get synthesisFingerprint => _fingerprint;

  /// Bind a genuine app-sandbox root; native code additionally validates every
  /// component and exclusively creates only content-addressed staging targets.
  Future<void> initialize(Directory root) async {
    if (await FileSystemEntity.type(root.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException(
        'Narration storage cannot be a symbolic link.',
      );
    }
    await root.create(recursive: true);
    await _channel.invokeMethod<void>('initialize', {
      'root': root.absolute.path,
    });
    final response = await _channel.invokeMapMethod<String, dynamic>('voices');
    if (response == null ||
        response['voices'] is! List ||
        response['synthesisFingerprint'] is! String) {
      throw const FormatException(
        'Apple narration returned an invalid voice catalog.',
      );
    }
    _voices = List.unmodifiable(
      (response['voices'] as List).map((value) {
        final voice = (value as Map).cast<String, dynamic>();
        return NarrationVoice(
          identifier: 'apple:${voice['identifier'] as String}',
          name: voice['name'] as String,
          language: voice['language'] as String,
          quality: voice['quality'] as String,
        );
      }),
    );
    final nativeDefault = response['defaultIdentifier'] as String?;
    _defaultVoice = nativeDefault == null ? null : 'apple:$nativeDefault';
    _fingerprint = response['synthesisFingerprint'] as String;
  }

  /// Native sentence UTF-16 pairs keyed by stable normalized source block ID.
  Future<Map<String, List<({int start, int end})>>> sentenceRanges(
    TextSection section, {
    String? language,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'sentenceRanges',
      {
        'blocks': section.blocks
            .map((block) => {'id': block.id, 'text': block.text})
            .toList(growable: false),
        'language': language,
      },
    );
    if (result == null) {
      throw const FormatException(
        'Apple sentence tokenization returned no result.',
      );
    }
    return result.map(
      (id, values) => MapEntry(
        id,
        (values as List)
            .map((value) {
              final pair = value as Map;
              return (start: pair['start'] as int, end: pair['end'] as int);
            })
            .toList(growable: false),
      ),
    );
  }

  /// Returns bounded raw source-format/marker evidence after the WAV has closed.
  /// Marker offsets alone are not a clock; the source accepts only independently
  /// verified utterance-relative PCM layouts, otherwise sentence fallback wins.
  Future<Map<String, dynamic>> synthesize({
    required int generation,
    required String text,
    required String voice,
    required String stagingPath,
    bool Function()? isCurrent,
  }) async {
    final staging = File(stagingPath);
    final directory = await staging.parent.resolveSymbolicLinks();
    final canonicalPath = '$directory/${staging.uri.pathSegments.last}';
    if (isCurrent != null && !isCurrent()) {
      throw StateError('Narration cancelled.');
    }
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'synthesize',
      {
        'requestId': 'dart-${++_request}',
        'generation': generation,
        'text': text,
        'voice': voice.startsWith('apple:') ? voice.substring(6) : voice,
        'stagingPath': canonicalPath,
      },
    );
    if (result == null) {
      throw const FormatException(
        'Device speech did not finalize an audio file.',
      );
    }
    return result;
  }

  /// Settles cancelled channel writers without waiting on the store write queue.
  Future<void> cancelGeneration(int generation) => _channel.invokeMethod<void>(
    'cancelGeneration',
    {'generation': generation},
  );
}
