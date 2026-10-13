/// Lowercase SHA-256 hex digest: import hashes, document digests, cache keys,
/// generation identities and narration's server-issued book and job IDs.
final sha256Hex = RegExp(r'^[a-f0-9]{64}$');

/// Forty lowercase hex digits: server-issued illustration and analysis book,
/// job and scene IDs.
final cloudIdHex = RegExp(r'^[a-f0-9]{40}$');
