import '../util/apart.dart';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// How many times the passphrase is stirred before it becomes a key. OWASP advises 600 000 for PBKDF2-HMAC-SHA256, but the
/// `cryptography` package computes it in Dart: 250 000 take about a second on a desktop (measured, compiled ahead of time), 600 000
/// about two and a half, and a phone is slower still, at every opening of a note. Raise this once the key is made natively (or with
/// a memory-hard function): each lock keeps the number it was made with, and a lock made with fewer is made again with the
/// new number the next time its secret is entered ([NoteLockService.unlock]).
const lockIterations = 250000;

Uint8List randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Future<Uint8List> _derive(String secret, Uint8List salt, int iterations, int bits) async {
  final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: bits);
  final key = await kdf.deriveKeyFromPassword(password: secret, nonce: salt);
  return Uint8List.fromList(await key.extractBytes());
}

/// The key a passphrase makes with [salt] (32 bytes), worked out away from the screen.
Future<Uint8List> deriveKey(String passphrase, Uint8List salt, int iterations) =>
    runApart(() => _derive(passphrase, salt, iterations, 256));

/// What a passcode is checked against: not the key of an encrypted note, a hash made with another salt.
Future<Uint8List> passcodeVerifier(String passcode, Uint8List salt, int iterations) =>
    runApart(() => _derive('verify:$passcode', salt, iterations, 256));

/// [clear] encrypted under [key] (AES-256-GCM); the answer is the new nonce and the cipher text with its authentication tag.
Future<({Uint8List nonce, Uint8List data})> encrypt(Uint8List key, Uint8List clear) => runApart(() async {
      final box = await AesGcm.with256bits().encrypt(clear, secretKey: SecretKey(key));
      return (nonce: Uint8List.fromList(box.nonce), data: Uint8List.fromList(box.concatenation(nonce: false)));
    });

/// What [encrypt] made, read again; null if the key is wrong or the data was changed.
Future<Uint8List?> decrypt(Uint8List key, Uint8List nonce, Uint8List data) => runApart(() async {
      try {
        final box = SecretBox.fromConcatenation([...nonce, ...data], nonceLength: nonce.length, macLength: 16);
        return Uint8List.fromList(await AesGcm.with256bits().decrypt(box, secretKey: SecretKey(key)));
      } on SecretBoxAuthenticationError {
        return null;
      }
    });

/// Whether two byte strings are the same, in a time that does not depend on where they differ.
bool sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
