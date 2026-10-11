import '../text/text_position.dart';

/// Durable per-book registration and interrupted playback, independent of catalogs.
class NarrationManifest {
  /// Local playback needs no registration; legacy sidecars remain cloud-owned.
  const NarrationManifest({
    this.account,
    this.cloudBookId,
    this.voice = 'marin',
    this.speed = 1,
    this.engine = 'openai-realtime',
    this.synthesisFingerprint = 'gpt-realtime-2.1-mini',
    this.segmentationPolicy = 'cloud-paragraph-v1',
    this.anchor,
    this.chunkId,
    this.chunkStart,
    this.offsetMs = 0,
  });

  /// Account identity isolates audio from another signed-in user's allowance.
  final String? account;

  /// Authenticated private-cloud registration, not a prose-upload permission.
  final String? cloudBookId;

  /// Voice identifying cached audio and resume offsets, not a book preference.
  final String voice;

  /// Legacy resume multiplier retained for sidecar compatibility; global
  /// preferences are authoritative when attaching this book.
  final double speed;

  /// Actual synthesis engine; old cloud offsets never become local clip offsets.
  final String engine;

  /// Provider/OS synthesis identity fences cached audio across engine upgrades.
  final String synthesisFingerprint;

  /// Batching policy identifying the exact generated clip boundaries.
  final String segmentationPolicy;

  /// Complete catalog anchor; starting or seeking audio never advances it.
  final TextPosition? anchor;

  /// Exact chunk identity guards resume against navigation or document changes.
  final String? chunkId;

  /// Complete start of the active or pending chunk, independently of [anchor].
  /// Read from here may begin elsewhere without committing catalog progress.
  final TextPosition? chunkStart;

  /// Audio time within the interrupted chunk; never used as text progress.
  final int offsetMs;

  /// Versioned sidecar representation; all position components are retained.
  Map<String, dynamic> toJson() => {
    'version': 2,
    'account': account,
    'cloudBookId': cloudBookId,
    'voice': voice,
    'speed': speed,
    'engine': engine,
    'synthesisFingerprint': synthesisFingerprint,
    'segmentationPolicy': segmentationPolicy,
    'anchor': anchor?.toJson(),
    'chunkId': chunkId,
    'chunkStart': chunkStart?.toJson(),
    'offsetMs': offsetMs,
  };

  /// Rejects incompatible sidecars instead of interpreting partial anchors.
  factory NarrationManifest.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 && json['version'] != 2) {
      throw const FormatException('Unknown narration version');
    }
    final voice = json['voice'] as String;
    final speed = (json['speed'] as num).toDouble();
    final offset = json['offsetMs'] as int;
    final engine = json['version'] == 1
        ? 'openai-realtime'
        : json['engine'] as String;
    final fingerprint = json['version'] == 1
        ? 'gpt-realtime-2.1-mini'
        : json['synthesisFingerprint'] as String;
    final policy = json['version'] == 1
        ? 'cloud-paragraph-v1'
        : json['segmentationPolicy'] as String;
    final validVoice =
        ['marin', 'cedar'].contains(voice) ||
        (voice.startsWith('apple:') && voice.length > 6);
    if (!validVoice ||
        !['openai-realtime', 'apple-avspeech'].contains(engine) ||
        policy !=
            (engine == 'apple-avspeech'
                ? 'apple-sentence-v1'
                : 'cloud-paragraph-v1') ||
        fingerprint.isEmpty ||
        !speed.isFinite ||
        speed < .75 ||
        speed > 2 ||
        offset < 0) {
      throw const FormatException('Invalid narration resume');
    }
    return NarrationManifest(
      account: json['account'] as String?,
      cloudBookId: json['cloudBookId'] as String?,
      voice: voice,
      speed: speed,
      engine: engine,
      synthesisFingerprint: fingerprint,
      segmentationPolicy: policy,
      anchor: json['anchor'] == null
          ? null
          : TextPosition.fromJson(
              (json['anchor'] as Map).cast<String, dynamic>(),
            ),
      chunkId: json['chunkId'] as String?,
      chunkStart: json['chunkStart'] == null
          ? null
          : TextPosition.fromJson(
              (json['chunkStart'] as Map).cast<String, dynamic>(),
            ),
      offsetMs: offset,
    );
  }
}
