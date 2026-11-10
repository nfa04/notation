import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';

import '../collab/secure_box.dart';

final _ed25519 = Ed25519();

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _randomBytes(int n, Random? random) {
  final r = random ?? Random.secure();
  return Uint8List.fromList([for (var i = 0; i < n; i++) r.nextInt(256)]);
}

/// The secret of a profile: 32 random bytes, made on the first device that offers to sync and carried to the others in the
/// link (after the `#`, so it never reaches a server). Everything the devices of one profile share is derived from it, each
/// use with a key of its own that does not give away the others:
///
///  * the *room* on the signalling server: the hash of a public key whose private half only holders of the secret can make,
///    so the server can check that a device that comes into the room knows the secret without ever learning it;
///  * the key that seals the messages between the devices (the signalling server and the data channel only carry ciphertext);
///  * the key of the six digits two devices compare when they are paired.
///
/// The secret alone is not enough to be part of a profile: a device must also be on the list of devices (see [DeviceIdentity]).
class SyncSecret {
  static const length = 32;

  final Uint8List bytes;

  SyncSecret(this.bytes) {
    if (bytes.length != length) throw ArgumentError('a sync secret has $length bytes');
  }

  factory SyncSecret.create([Random? random]) => SyncSecret(_randomBytes(length, random));

  /// The key that seals every message between the devices.
  Uint8List get messageKey => deriveKey(bytes, 'sync-messages');

  /// The key the files of the sync through a cloud folder are sealed with.
  Uint8List get cloudKey => deriveKey(bytes, 'sync-cloud-files');

  Uint8List get _pairingKey => deriveKey(bytes, 'sync-pairing');

  /// The number of the day (UTC) the rooms are named for: the room of a profile changes every day, so that the server cannot
  /// tell that the same profile came back tomorrow, or build up when its devices are usually online.
  static int epochNow([DateTime? now]) => (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

  /// How long until the room changes.
  static Duration untilNextEpoch([DateTime? now]) {
    final t = (now ?? DateTime.now()).toUtc();
    return DateTime.utc(t.year, t.month, t.day + 1).difference(t);
  }

  /// The key pair whose public half names the room and whose private half proves to the server that this device knows the
  /// secret. Made from the secret and the day ([epoch], today by default), so every device of the profile makes the same one.
  Future<RoomKeys> roomKeys({int? epoch}) async {
    final pair = await _ed25519.newKeyPairFromSeed(deriveKey(bytes, 'sync-room-seed-${epoch ?? epochNow()}'));
    final pub = Uint8List.fromList((await pair.extractPublicKey()).bytes);
    return RoomKeys._(pair, pub);
  }

  /// Six digits that both devices of a pairing show. They come from the secret, from the public keys of both devices, from
  /// a random number of each and from the connection's [binding], so a device in the middle - whether it uses a key of its own or
  /// only passes the messages on while it sits in the encrypted connection - makes them differ on the two sides.
  String pairingCode({required String nonceA, required String nonceB, required Uint8List publicKeyA, required Uint8List publicKeyB, String binding = ''}) {
    // the order does not matter: both sides get the same digits
    final parts = [
      '$nonceA|${base64.encode(publicKeyA)}',
      '$nonceB|${base64.encode(publicKeyB)}',
    ]..sort();
    final mac = hash.Hmac(hash.sha256, _pairingKey).convert(utf8.encode('${parts.join('||')}###$binding')).bytes;
    final n = (mac[0] << 24 | mac[1] << 16 | mac[2] << 8 | mac[3]) & 0x7fffffff;
    final digits = (n % 1000000).toString().padLeft(6, '0');
    return '${digits.substring(0, 3)} ${digits.substring(3)}';
  }

  /// The secret as text for a link.
  String toText() => base64Url.encode(bytes).replaceAll('=', '');

  static SyncSecret? fromText(String text) {
    try {
      final padded = text + '=' * ((4 - text.length % 4) % 4);
      final bytes = base64Url.decode(padded);
      return bytes.length == length ? SyncSecret(Uint8List.fromList(bytes)) : null;
    } on FormatException {
      return null;
    }
  }
}

/// What the signalling server checks: that the device holds the private key of the public key the room is named after.
class RoomKeys {
  final SimpleKeyPair _pair;
  final Uint8List publicKey;

  RoomKeys._(this._pair, this.publicKey);

  /// 32 hex digits: the start of the hash of the public key.
  String get room => roomOf(publicKey);

  /// The room a public key names.
  static String roomOf(List<int> publicKey) => _hex(hash.sha256.convert(publicKey).bytes.sublist(0, 16));

  /// What the server asks to be signed when a device comes into [room] (the server's own random [nonce] makes it new every time).
  static List<int> challengeBytes(String room, String nonce) => utf8.encode('uninotes-sync-v1|$room|$nonce');

  /// The signature that answers the server's [nonce].
  Future<Uint8List> answer(String nonce) async => Uint8List.fromList((await _ed25519.sign(challengeBytes(room, nonce), keyPair: _pair)).bytes);

  /// Whether [signature] answers [nonce] for the room that [publicKey] names (what a server does).
  static Future<bool> verify(Uint8List publicKey, String room, String nonce, Uint8List signature) async {
    if (publicKey.length != 32 || signature.length != 64 || roomOf(publicKey) != room) return false;
    return _ed25519.verify(challengeBytes(room, nonce), signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)));
  }
}

/// This device, as the others of its profile know it: an id, and a key pair of its own whose private half (the *device secret*)
/// never leaves the device. A device is part of a profile only once another device has accepted its public key; from then on
/// it proves who it is, every time it connects, by signing a challenge that both sides contribute to.
class DeviceIdentity {
  /// 16 hex digits.
  final String id;
  final Uint8List _seed;
  final Uint8List publicKey;

  DeviceIdentity._(this.id, this._seed, this.publicKey);

  /// The secret half, to be kept in the secure storage of the system.
  Uint8List get seed => _seed;

  static Future<DeviceIdentity> create({Random? random}) async {
    final seed = _randomBytes(32, random);
    return fromSeed(_hex(_randomBytes(8, random)), seed);
  }

  static Future<DeviceIdentity> fromSeed(String id, Uint8List seed) async {
    final pair = await _ed25519.newKeyPairFromSeed(seed);
    return DeviceIdentity._(id, seed, Uint8List.fromList((await pair.extractPublicKey()).bytes));
  }

  Future<Uint8List> sign(List<int> message) async {
    final pair = await _ed25519.newKeyPairFromSeed(_seed);
    return Uint8List.fromList((await _ed25519.sign(message, keyPair: pair)).bytes);
  }

  static Future<bool> verify(Uint8List publicKey, List<int> message, Uint8List signature) async {
    if (publicKey.length != 32 || signature.length != 64) return false;
    return _ed25519.verify(message, signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)));
  }

  /// What two devices sign when they meet. It holds the room, both ids and both nonces (each side picks one), the connection's
  /// binding (so that a proof cannot be carried over to another connection by a device that sits in between), and whose
  /// signature it is, so a signature made for one meeting cannot be used in another, or reflected back at its maker.
  static List<int> meeting({required String room, required String signerId, required String idA, required String nonceA, required String idB, required String nonceB, String binding = ''}) {
    final sides = ['$idA:$nonceA', '$idB:$nonceB']..sort();
    return utf8.encode('uninotes-device-v1|$room|${sides.join('|')}|$binding|signed by $signerId');
  }
}

/// A fresh random text for a challenge (16 bytes as hex).
String newNonce([Random? random]) => _hex(_randomBytes(16, random));
