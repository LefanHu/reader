import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Account-scoped HMAC of a book hash shared by every cloud feature.
String cloudBookFingerprint(String hash, String key) =>
    Hmac(sha256, base64Decode(key)).convert(utf8.encode(hash)).toString();
