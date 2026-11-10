import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter/foundation.dart' show compute;

import 'package:cryptography/cryptography.dart';

/// Seals and opens messages with the key of a session (XChaCha20-Poly1305: nothing can be read
/// or changed without the key, and a message that was changed does not open). Each message has
/// a random nonce of its own, sent along in front of it.
class SecureBox {
  static final _cipher = Xchacha20.poly1305Aead();
  final SecretKey _key;

  SecureBox(Uint8List key) : _key = SecretKey(key);

  Future<Uint8List> seal(Uint8List plain, {List<int> aad = const []}) async {
    final box = await _cipher.encrypt(plain, secretKey: _key, aad: aad);
    return Uint8List.fromList(box.concatenation());
  }

  /// The message, or a [SecretBoxAuthenticationError] if it was not sealed with this key or was changed.
  Future<Uint8List> open(Uint8List sealed, {List<int> aad = const []}) async {
    final box = SecretBox.fromConcatenation(sealed, nonceLength: 24, macLength: 16);
    return Uint8List.fromList(await _cipher.decrypt(box, secretKey: _key, aad: aad));
  }
}

/// The messages that devices send each other through a server that relays them, as the server sees them: `{"p": <sealed>}`, a
/// message (JSON) padded to a multiple of one size (see [padMessage]) and sealed.
extension SealedMessages on SecureBox {
  Future<String> sealMessage(Map<String, Object?> message) async => jsonEncode({'p': base64Encode(await seal(padMessage(jsonEncode(message))))});

  /// The message in [outer] (a decoded `{"p": ...}`), or an error if it is not sealed with this key.
  Future<Map<String, Object?>> openMessage(Map<Object?, Object?> outer) async {
    final plain = await open(Uint8List.fromList(base64Decode(outer['p'] as String)));
    return (jsonDecode(utf8.decode(plain)) as Map).cast<String, Object?>();
  }
}

/// From this many bytes on sealing and opening is done on another isolate: the cipher is Dart code, and a note with a PDF in it takes
/// seconds of processor time that would stop the screen (and, when a sync does it file after file, make the sync itself slow).
const int sealApartFrom = 256 * 1024;

/// [plain] sealed with [key], apart from the screen when it is big. [aad] is authenticated with it (not stored): opening needs the same.
Future<Uint8List> sealApart(Uint8List key, Uint8List plain, {List<int> aad = const []}) =>
    plain.length < sealApartFrom ? SecureBox(key).seal(plain, aad: aad) : compute(_sealIn, (key, plain, aad));

/// [sealed] opened with [key], apart from the screen when it is big. Throws as [SecureBox.open] does.
Future<Uint8List> openApart(Uint8List key, Uint8List sealed, {List<int> aad = const []}) =>
    sealed.length < sealApartFrom ? SecureBox(key).open(sealed, aad: aad) : compute(_openIn, (key, sealed, aad));

Future<Uint8List> _sealIn((Uint8List, Uint8List, List<int>) a) => SecureBox(a.$1).seal(a.$2, aad: a.$3);

Future<Uint8List> _openIn((Uint8List, Uint8List, List<int>) a) => SecureBox(a.$1).open(a.$2, aad: a.$3);

/// A key for one purpose from the secret of a link (HKDF-SHA256, RFC 5869), so that what is sealed for different
/// purposes (the copy, its marker, messages to its owner) never shares a key.
Uint8List deriveKey(Uint8List secret, String purpose, {int length = 32}) {
  final prk = hash.Hmac(hash.sha256, utf8.encode('uninotes-link-v1')).convert(secret).bytes;
  final out = <int>[];
  var block = <int>[];
  for (var i = 1; out.length < length; i++) {
    block = hash.Hmac(hash.sha256, prk).convert([...block, ...utf8.encode(purpose), i]).bytes;
    out.addAll(block);
  }
  return Uint8List.fromList(out.sublist(0, length));
}


/// [json] with spaces added (JSON ignores them) until its UTF-8 form is a multiple of [block] bytes. Sealed, a message then says
/// nothing of what kind it is by its length: to a server that relays them a greeting, an answer and a connection candidate all
/// look the same.
Uint8List padMessage(String json, {int block = 4096}) {
  final bytes = utf8.encode(json);
  final size = ((bytes.length + block - 1) ~/ block) * block;
  final out = Uint8List(size)..fillRange(0, size, 0x20);
  out.setRange(0, bytes.length, bytes);
  return out;
}
