import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

/// Lines for the console about who is who in the sync (ids and the start of public keys, never a secret), so that a refusal such as "the
/// key of the other device is not the one that was accepted" can be traced to the device that has the wrong key. Every line starts with
/// `[sync-diag]`; filter the console for it.
void syncDiag(String line) => debugPrint('[sync-diag] $line');

/// The start of a public key, enough to tell two keys apart (the same ten characters the device list stores).
String keyTag(Uint8List? key) {
  if (key == null) return 'null';
  final text = base64.encode(key);
  return text.length <= 10 ? text : text.substring(0, 10);
}
