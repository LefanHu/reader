import '../text/document.dart';

/// Durable per-book opt-in and interrupted playback, independent of catalogs.
class NarrationManifest {
  /// Old books default to no consent; resume never implicitly starts playback.
  const NarrationManifest({
    this.account,
    this.cloudBookId,
    this.voice = 'marin',
    this.speed = 1,
    this.anchor,
    this.chunkId,
    this.offsetMs = 0,
  });

  /// Account identity isolates audio from another signed-in user's allowance.
  final String? account;

  /// Registration receipt also records explicit per-book consent.
  final String? cloudBookId;

  /// Provider voice; changing it invalidates audio offsets and cache identity.
  final String voice;

  /// Local playback multiplier, independent of provider generation settings.
  final double speed;

  /// Complete committed logical position at the beginning of the resume chunk.
  final TextPosition? anchor;

  /// Exact chunk identity guards resume against navigation or document changes.
  final String? chunkId;

  /// Audio time within the interrupted chunk; never used as text progress.
  final int offsetMs;

  /// Versioned sidecar representation; all position components are retained.
  Map<String, dynamic> toJson() => {
    'version': 1,
    'account': account,
    'cloudBookId': cloudBookId,
    'voice': voice,
    'speed': speed,
    'anchor': anchor?.toJson(),
    'chunkId': chunkId,
    'offsetMs': offsetMs,
  };

  /// Rejects incompatible sidecars instead of interpreting partial anchors.
  factory NarrationManifest.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unknown narration version');
    }
    final voice = json['voice'] as String;
    final speed = (json['speed'] as num).toDouble();
    final offset = json['offsetMs'] as int;
    if (!['marin', 'cedar'].contains(voice) ||
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
      anchor: json['anchor'] == null
          ? null
          : TextPosition.fromJson(
              (json['anchor'] as Map).cast<String, dynamic>(),
            ),
      chunkId: json['chunkId'] as String?,
      offsetMs: offset,
    );
  }
}

/// Registration and current UTC-month allowance returned by the private API.
class NarrationRegistration {
  /// The server account ID is included in every local audio cache identity.
  const NarrationRegistration(this.account, this.bookId, this.remaining);

  /// Authenticated Firebase user owning this registration.
  final String account;

  /// Private narration book registration, separate from illustration credits.
  final String bookId;

  /// Remaining UTF-16 input units; cached replay consumes none.
  final int remaining;
}
