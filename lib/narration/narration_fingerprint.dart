import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Account-scoped fingerprint matches the existing cloud privacy boundary.
String narrationFingerprint(String hash, String key) =>
    Hmac(sha256, base64Decode(key)).convert(utf8.encode(hash)).toString();
