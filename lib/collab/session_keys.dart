import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The signing key of one device in one live session (Ed25519). It is made for the session and thrown away with it: nothing ties it to
/// the device or to the person, so what a person does in one session cannot be linked to another.
///
/// The invite's key only says that a device is a member (every member can write everything, and so can claim to be anybody); a
/// signature with this key says that a message comes from the one device that registered the key with the host.
class SessionKeys {
  static final _ed25519 = Ed25519();

  final Uint8List _seed;
  final Uint8List publicKey;

  SessionKeys._(this._seed, this.publicKey);

  /// The keys that [seed] (32 random bytes, kept by the session) stands for.
  static Future<SessionKeys> fromSeed(Uint8List seed) async {
    final pair = await _ed25519.newKeyPairFromSeed(seed);
    final pub = await pair.extractPublicKey();
    return SessionKeys._(Uint8List.fromList(seed), Uint8List.fromList(pub.bytes));
  }

  /// [publicKey] as text, as it travels in messages.
  String get publicKeyText => base64Encode(publicKey);

  Future<Uint8List> sign(List<int> message) async {
    final pair = await _ed25519.newKeyPairFromSeed(_seed);
    return Uint8List.fromList((await _ed25519.sign(message, keyPair: pair)).bytes);
  }

  Future<String> signText(List<int> message) async => base64Encode(await sign(message));

  /// Whether [signature] is [publicKey]'s signature of [message]. Anything that is not a key or a signature is just false.
  static Future<bool> verify(Uint8List publicKey, List<int> message, Uint8List signature) async {
    if (publicKey.length != 32 || signature.length != 64) return false;
    try {
      return await _ed25519.verify(message, signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)));
    } catch (_) {
      return false;
    }
  }

  /// [verify] with the key and the signature as the text they travel as (false for text that is not base64).
  static Future<bool> verifyText(String? publicKey, List<int> message, String? signature) async {
    if (publicKey == null || signature == null) return false;
    try {
      return await verify(Uint8List.fromList(base64Decode(publicKey)), message, Uint8List.fromList(base64Decode(signature)));
    } catch (_) {
      return false;
    }
  }

  /// What a guest signs to show that it holds the key it asks to be registered with: the session, who it says it is, and the nonce of this
  /// very request (so that a signature cannot be used again for another request).
  static List<int> joinProof(String site, String nonce, String publicKey) => utf8.encode(jsonEncode(['notation-live-join-v1', site, nonce, publicKey]));

  /// What [from] signs on a direct link to [to] (a link to a successor, see [WarmNet]): the [nonce] of the device that connected and the
  /// [binding] of the link itself. A device in the middle that passes the messages on has links of its own, with other bindings: the
  /// signature it passes on does not fit them.
  static List<int> linkProof(String from, String to, String nonce, String binding) =>
      utf8.encode(jsonEncode(['notation-live-link-v1', from, to, nonce, binding]));
}
