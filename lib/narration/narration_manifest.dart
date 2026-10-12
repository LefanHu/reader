import '../text/text_position.dart';

/// Durable per-book registration and interrupted playback, independent of catalogs.
class NarrationManifest {
  /// Local playback needs no registration.
  const NarrationManifest({
    this.account,
    this.cloudBookId,
    this.voice = 'marin',
    this.speed = 1,
    this.engine = 'openai-realtime',
    this.synthesisFingerprint = 'gpt-realtime-2.1-mini',
    this.segmentationPolicy = 'cloud-paragraph',
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

  /// Playback multiplier mirrored from global preferences, which stay
  /// authoritative when attaching this book.
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

  /// Replaces interrupted playback, keeping registration and synthesis identity.
  /// Every argument replaces its field; null clears it.
  NarrationManifest withPlayback({
    required TextPosition? anchor,
    String? chunkId,
    required TextPosition? chunkStart,
    int offsetMs = 0,
  }) => NarrationManifest(
    account: account,
    cloudBookId: cloudBookId,
    voice: voice,
    speed: speed,
    engine: engine,
    synthesisFingerprint: synthesisFingerprint,
    segmentationPolicy: segmentationPolicy,
    anchor: anchor,
    chunkId: chunkId,
    chunkStart: chunkStart,
    offsetMs: offsetMs,
  );

  /// Clears interrupted playback; a null [anchor] clears the anchor too.
  NarrationManifest withoutPlayback({TextPosition? anchor}) =>
      withPlayback(anchor: anchor, chunkStart: null);

  /// Records a new cloud registration; earlier playback is cleared.
  NarrationManifest withRegistration({
    required String account,
    required String cloudBookId,
    required TextPosition? anchor,
  }) => NarrationManifest(
    account: account,
    cloudBookId: cloudBookId,
    voice: voice,
    speed: speed,
    engine: engine,
    synthesisFingerprint: synthesisFingerprint,
    segmentationPolicy: segmentationPolicy,
    anchor: anchor,
  );

  /// Forgets cloud registration while keeping synthesis identity; playback is
  /// cleared.
  NarrationManifest withoutRegistration({required TextPosition? anchor}) =>
      NarrationManifest(
        voice: voice,
        speed: speed,
        engine: engine,
        synthesisFingerprint: synthesisFingerprint,
        segmentationPolicy: segmentationPolicy,
        anchor: anchor,
      );

  /// Applies a synthesis profile. Interrupted offsets survive only when voice,
  /// engine, fingerprint and policy are unchanged; speed reuses existing audio.
  NarrationManifest withProfile({
    required String voice,
    required double speed,
    required String engine,
    required String synthesisFingerprint,
    required String segmentationPolicy,
    required TextPosition? anchor,
  }) {
    final same =
        voice == this.voice &&
        engine == this.engine &&
        synthesisFingerprint == this.synthesisFingerprint &&
        segmentationPolicy == this.segmentationPolicy;
    return NarrationManifest(
      account: account,
      cloudBookId: cloudBookId,
      voice: voice,
      speed: speed,
      engine: engine,
      synthesisFingerprint: synthesisFingerprint,
      segmentationPolicy: segmentationPolicy,
      anchor: anchor,
      chunkId: same ? chunkId : null,
      chunkStart: chunkStart,
      offsetMs: same ? offsetMs : 0,
    );
  }

  /// Sidecar representation; all position components are retained.
  Map<String, dynamic> toJson() => {
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
    final voice = json['voice'] as String;
    final speed = (json['speed'] as num).toDouble();
    final offset = json['offsetMs'] as int;
    final engine = json['engine'] as String;
    final fingerprint = json['synthesisFingerprint'] as String;
    final policy = json['segmentationPolicy'] as String;
    final validVoice =
        ['marin', 'cedar'].contains(voice) ||
        (voice.startsWith('apple:') && voice.length > 6);
    if (!validVoice ||
        !['openai-realtime', 'apple-avspeech'].contains(engine) ||
        policy !=
            (engine == 'apple-avspeech'
                ? 'apple-sentence'
                : 'cloud-paragraph') ||
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
