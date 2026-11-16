import '../util/apart.dart';
import '../util/native_crypto.dart';
import 'pbkdf2_native_io.dart' if (dart.library.js_interop) 'pbkdf2_native_web.dart';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// How many times the passphrase is stirred before it becomes a key. OWASP advises 600 000 for PBKDF2-HMAC-SHA256, but the
/// `cryptography` package computes it in Dart: 250 000 take about a second on a desktop (measured, compiled ahead of time), 600 000
/// about two and a half, and a phone is slower still, at every opening of a note. Raise this once the key is made natively (or with
/// a memory-hard function): each lock keeps the number it was made with, and a lock made with fewer is made again with the
/// new number the next time its secret is entered ([NoteLockService.unlock]).
const _dartIterations = 250000;

/// What a new lock is made with: 600 000 (the figure OWASP advises) where the stretching is not done in Dart and has been seen to run
/// fast (the system's code on Android, OpenSSL on Linux), else 250 000 (Windows, iOS, macOS, the browser: not measured there).
int get lockIterations => platformPbkdf2On || pbkdf2IsNative ? 600000 : _dartIterations;

/// Runs [f] away from the screen: on another isolate, unless the system does it (the plugin only works on this isolate, and does its
/// work on a thread of the system); [onMain] says whether that is so for this work.
Future<T> _away<T>(Future<T> Function() f, {required bool onMain}) => onMain ? f() : runApart(f);

Uint8List randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Future<Uint8List> _derive(String secret, Uint8List salt, int iterations, int bits) async {
  final fast = pbkdf2Native(secret, salt, iterations, bits ~/ 8);
  if (fast != null) return fast;
  final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: bits);
  final key = await kdf.deriveKeyFromPassword(password: secret, nonce: salt);
  return Uint8List.fromList(await key.extractBytes());
}

/// The key a passphrase makes with [salt] (32 bytes), worked out away from the screen.
Future<Uint8List> deriveKey(String passphrase, Uint8List salt, int iterations) =>
    _away(() => _derive(passphrase, salt, iterations, 256), onMain: platformPbkdf2On);

/// What a passcode is checked against: not the key of an encrypted note, a hash made with another salt.
Future<Uint8List> passcodeVerifier(String passcode, Uint8List salt, int iterations) =>
    _away(() => _derive('verify:$passcode', salt, iterations, 256), onMain: platformPbkdf2On);

/// [clear] encrypted under [key] (AES-256-GCM); the answer is the new nonce and the cipher text with its authentication tag.
Future<({Uint8List nonce, Uint8List data})> encrypt(Uint8List key, Uint8List clear) => _away(() async {
      final box = await AesGcm.with256bits().encrypt(clear, secretKey: SecretKey(key));
      return (nonce: Uint8List.fromList(box.nonce), data: Uint8List.fromList(box.concatenation(nonce: false)));
    }, onMain: platformCryptoOn && clear.length <= platformCryptoMostBytes);

/// What [encrypt] made, read again; null if the key is wrong or the data was changed.
Future<Uint8List?> decrypt(Uint8List key, Uint8List nonce, Uint8List data) => _away(() async {
      try {
        // (joined as bytes: a list literal of the two would hold every byte as an object, eight times the size of the note)
        final joined = Uint8List(nonce.length + data.length)
          ..setAll(0, nonce)
          ..setAll(nonce.length, data);
        final box = SecretBox.fromConcatenation(joined, nonceLength: nonce.length, macLength: 16);
        return Uint8List.fromList(await AesGcm.with256bits().decrypt(box, secretKey: SecretKey(key)));
      } on SecretBoxAuthenticationError {
        return null;
      }
    }, onMain: platformCryptoOn && data.length <= platformCryptoMostBytes);

/// Whether two byte strings are the same, in a time that does not depend on where they differ.
bool sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
