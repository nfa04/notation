import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../collab/secure_box.dart';
import '../data/settings_repository.dart';
import '../devicesync/device_sync_service.dart';
import '../devicesync/sync_devices.dart';
import '../devicesync/sync_diag.dart';
import '../devicesync/sync_keys.dart';
import '../l10n/language.dart';
import 'cloud_folder.dart';
import 'cloud_sync_service.dart';
import 'folder_sync.dart';

/// The recovery key: what a person types (or pastes) on a new device to sign in with their cloud folder. about 123 random bits as five
/// groups of five characters (no 0/O or 1/I/L to mix up). It is made once, shown once, and kept by the person (a password manager, a
/// sheet of paper); the devices of the profile do not keep it. Everything the sign-in needs is derived from it with HKDF, so it needs no
/// slow key stretching: there is nothing to guess.
class RecoveryKey {
  /// 31 characters: no 0/O, 1/I/L (about 4.95 bits each, so 25 of them are 123 bits).
  static const _alphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  static const groups = 5, groupLength = 5;

  /// The characters of the key without the dashes (25).
  final String chars;

  const RecoveryKey._(this.chars);

  factory RecoveryKey.create([Random? random]) {
    final r = random ?? Random.secure();
    return RecoveryKey._(String.fromCharCodes([for (var i = 0; i < groups * groupLength; i++) _alphabet.codeUnitAt(r.nextInt(_alphabet.length))]));
  }

  /// What the person typed or pasted, forgiving about case, dashes, spaces, and the look-alikes: null if it is not a key.
  static RecoveryKey? parse(String text) {
    final t = text.toUpperCase().replaceAll(RegExp(r'[\s\-_.]'), '');
    if (t.length != groups * groupLength) return null;
    for (final c in t.split('')) {
      if (!_alphabet.contains(c)) return null;
    }
    return RecoveryKey._(t);
  }

  /// `ABCDE-FGHJK-...`
  String get text => [for (var i = 0; i < groups; i++) chars.substring(i * groupLength, (i + 1) * groupLength)].join('-');

  Uint8List get _bytes => Uint8List.fromList(utf8.encode(chars));

  /// The key that seals the secret of the profile in the bootstrap file.
  Uint8List get wrapKey => deriveKey(_bytes, 'signin-wrap');

  Future<SimpleKeyPair> _enrollPair() => Ed25519().newKeyPairFromSeed(deriveKey(_bytes, 'signin-enroll-seed'));

  /// The public half of the key that signs the enrolment of a device. The devices of the profile hold it (as a setting of the profile,
  /// so it comes to them sealed); the private half exists only where the recovery key is typed in.
  Future<Uint8List> verifier() async => Uint8List.fromList((await (await _enrollPair()).extractPublicKey()).bytes);

  Future<Uint8List> _sign(List<int> message) async => Uint8List.fromList((await Ed25519().sign(message, keyPair: await _enrollPair())).bytes);
}

/// Somebody typed a recovery key that does not open the bootstrap file.
class WrongRecoveryKey implements Exception {
  @override
  String toString() => tr('That recovery key does not open this folder. Check it for typing mistakes, and that it is the latest one if you made a new key.');
}

/// What the person can sign in to: the profile that the bootstrap file holds.
class SignInProfile {
  final SyncSecret secret;
  final String profileId, profileName;
  final Uint8List verifier;

  /// The signalling server the devices of the profile meet on ('' when the file does not say: an older one).
  final String server;

  const SignInProfile(this.secret, this.profileId, this.profileName, this.verifier, [this.server = '']);
}

/// The bootstrap file in the folder: the secret of the profile (with the id and name of the profile, which a device that signs in
/// takes over) sealed with a key from the recovery key, and next to it, readable by anyone, the public key that checks enrolments.
/// The public key is also what the sealed part is tied to, so a folder service cannot swap the one for the other.
class SignInFile {
  static const version = 1;

  static List<int> _aad(Uint8List verifier) => utf8.encode('notation-signin-v1|${base64.encode(verifier)}');

  static Future<Uint8List> build(RecoveryKey key, SyncSecret secret, String profileId, String profileName, {String server = ''}) async {
    final verifier = await key.verifier();
    final plain = utf8.encode(jsonEncode({'secret': base64.encode(secret.bytes), 'id': profileId, 'name': profileName, if (server.isNotEmpty) 'server': server}));
    final sealed = await SecureBox(key.wrapKey).seal(Uint8List.fromList(plain), aad: _aad(verifier));
    return Uint8List.fromList(utf8.encode(jsonEncode({'v': version, 'verify': base64.encode(verifier), 'box': base64.encode(sealed)})));
  }

  /// The profile in [file], or [WrongRecoveryKey] when [key] does not open it; a [StateError] when it is not a file of this app (or
  /// from a newer one).
  static Future<SignInProfile> open(Uint8List file, RecoveryKey key) async {
    final Map<String, Object?> json;
    final Uint8List verifier, sealed;
    try {
      json = (jsonDecode(utf8.decode(file)) as Map).cast<String, Object?>();
      verifier = Uint8List.fromList(base64.decode(json['verify'] as String));
      sealed = Uint8List.fromList(base64.decode(json['box'] as String));
    } catch (_) {
      throw StateError(tr('The sign-in file in the folder cannot be read.'));
    }
    if (json['v'] != version) throw StateError(tr('The sign-in file in the folder is from a newer version of the app: update the app.'));
    final Uint8List plain;
    try {
      plain = await SecureBox(key.wrapKey).open(sealed, aad: _aad(verifier));
    } catch (_) {
      throw WrongRecoveryKey();
    }
    // (it opened, so it is the right key: the public key must be the one this key makes)
    final mine = await key.verifier();
    if (!listEquals(mine, verifier)) throw WrongRecoveryKey();
    final body = (jsonDecode(utf8.decode(plain)) as Map).cast<String, Object?>();
    final secret = SyncSecret.fromText(base64Url.encode(base64.decode(body['secret'] as String)).replaceAll('=', ''));
    if (secret == null) throw StateError(tr('The sign-in file in the folder cannot be read.'));
    return SignInProfile(secret, body['id'] as String? ?? '', body['name'] as String? ?? '', verifier, body['server'] as String? ?? '');
  }
}

/// A device that the holder of the recovery key vouched for: "this device, with this key, is one of the profile". Signed with the key
/// the recovery key makes, so a device that only knows the secret of the profile (one that was removed, say) cannot make one.
class Endorsement {
  final String id, name;
  final Uint8List publicKey;
  final int at;
  final Uint8List signature;

  const Endorsement(this.id, this.name, this.publicKey, this.at, this.signature);

  static List<int> _message(String id, String name, Uint8List publicKey, int at) => utf8.encode('notation-signin-join-v1|$id|${base64.encode(publicKey)}|$at|${base64.encode(utf8.encode(name))}');

  static Future<Endorsement> make(RecoveryKey key, PairedDevice d) async =>
      Endorsement(d.id, d.name, d.publicKey, d.addedAt, await key._sign(_message(d.id, d.name, d.publicKey, d.addedAt)));

  Future<bool> verify(Uint8List verifier) {
    if (verifier.length != 32 || signature.length != 64 || publicKey.length != 32) return Future.value(false);
    return Ed25519().verify(_message(id, name, publicKey, at), signature: Signature(signature, publicKey: SimplePublicKey(verifier, type: KeyPairType.ed25519)));
  }

  PairedDevice get device => PairedDevice(id: id, name: name, publicKey: publicKey, addedAt: at);

  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode({'id': id, 'name': name, 'key': base64.encode(publicKey), 'at': at, 'sig': base64.encode(signature)})));

  static Endorsement? fromBytes(Uint8List bytes) {
    try {
      final j = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
      return Endorsement(j['id'] as String, j['name'] as String, Uint8List.fromList(base64.decode(j['key'] as String)), j['at'] as int, Uint8List.fromList(base64.decode(j['sig'] as String)));
    } catch (_) {
      return null;
    }
  }
}

/// Signing in to the profile with the cloud folder instead of a link and a person's yes on another device. The folder holds, in a
/// directory `_profile` of its own, the bootstrap file (the secret, sealed with the recovery key) and an [Endorsement] for each device
/// (sealed with the key of the profile, so the service learns nothing from them).
///
/// This is an opt-in setting of the profile ([enabled]); the link pairing stays what it was. It trades one thing: a device is let in
/// by *having the recovery key and an account that reaches the folder* instead of by a person's yes on a device that is already in. The
/// devices that are in see every such device appear, and can remove it.
class CloudSignIn extends ChangeNotifier {
  /// The public key that checks enrolments, as text, or empty/absent when signing in is off. A setting of the profile: the devices
  /// that have it check the endorsements they find in the folder against it.
  static const kVerifier = 'sync_signin_verifier';

  /// Devices that came in with the recovery key (id -> when this device saw it), as a local note for the screen.
  static const _kVia = 'sync_signin_via';
  static const _kSeen = 'sync_signin_seen';

  static const dir = '_profile';
  static const bootstrapPath = '$dir/b';

  final SettingsRepository _settings;
  final DeviceSyncService _devices;
  final CloudSyncService _cloud;

  CloudSignIn(this._settings, this._devices, this._cloud);

  Uint8List? _verifier;
  Map<String, int> _via = {};
  Set<String> _seen = {};

  /// Signing in with the recovery key is on for this profile.
  bool get enabled => _verifier != null;

  /// The devices that were signed in with the recovery key and are still part of the profile (id -> when this device saw them come).
  Map<String, int> get signedIn => {for (final e in _via.entries) if (_devices.book.find(e.key) != null) e.key: e.value};

  Future<void> load() async {
    final v = await _settings.get(kVerifier);
    final before = _verifier;
    try {
      _verifier = v == null || v.isEmpty ? null : Uint8List.fromList(base64.decode(v));
      if (_verifier?.length != 32) _verifier = null;
    } on FormatException {
      _verifier = null;
    }
    // (another device turned it off, or made a new key: the endorsements that were looked at belong to the old one)
    final changed = !(before == null && _verifier == null) && !(before != null && _verifier != null && listEquals(before, _verifier));
    try {
      _via = {for (final e in (jsonDecode((await _settings.get(_kVia)) ?? '{}') as Map).entries) e.key as String: e.value as int};
      _seen = {for (final s in (jsonDecode((await _settings.get(_kSeen)) ?? '[]') as List)) s as String};
    } catch (_) {
      _via = {};
      _seen = {};
    }
    if (changed) {
      _seen = {};
      await _settings.set(_kSeen, '[]');
    }
    notifyListeners();
  }

  // ---- the files

  /// Where the endorsement of the device [id] made at [at] is: the name says nothing (a keyed hash). A device that signs in again makes a
  /// new one with a name of its own, so that the others, which note the names they have looked at, see it.
  static String endorsementPath(SyncSecret secret, String id, int at) =>
      '$dir/j-${hash.Hmac(hash.sha256, secret.cloudKey).convert(utf8.encode('join:$id:$at')).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().substring(0, 20)}';

  /// What a sealed file in the folder is tied to: the place it is stored at.
  static List<int> placeOf(String path) => utf8.encode('notation-signin-file-v1|$path');

  Future<void> _writeEndorsement(CloudFolder folder, SyncSecret secret, Endorsement e) {
    final path = endorsementPath(secret, e.id, e.at);
    syncDiag('sign-in: writing the endorsement of ${e.id} (${e.name}) with key ${keyTag(e.publicKey)} at ${e.at} to $path');
    return sealApart(secret.cloudKey, e.toBytes(), aad: placeOf(path)).then((sealed) => folder.write(path, sealed));
  }

  CloudFolder? _folder() => _cloud.folderNow;

  CloudFolder _needFolder() {
    final f = _folder();
    if (f == null) throw StateError(tr('Signing in needs the sync through a cloud folder to be on, with the account connected on this device.'));
    return f;
  }

  Future<void> _publish(CloudFolder folder, RecoveryKey key, SyncSecret secret) async {
    syncDiag('sign-in: publishing for the devices ${_devices.book.describe()}; server ${_devices.signalServer ?? '(none)'}');
    await folder.write(bootstrapPath, await SignInFile.build(key, secret, _devices.profileId, _devices.profileName, server: _devices.signalServer ?? ''));
    for (final d in _devices.book.active) {
      await _writeEndorsement(folder, secret, await Endorsement.make(key, d));
    }
  }

  // ---- turning it on and off

  /// Turns signing in on: makes a recovery key, puts the bootstrap file and an endorsement for each device that is part of the profile in
  /// the folder, and tells the other devices (a setting of the profile) which key to check endorsements against. Returns the key, to be
  /// shown to the person - it is not kept anywhere.
  Future<RecoveryKey> enable() async {
    await _devices.ensureProfile();
    final secret = _devices.profileSecret!;
    final folder = _needFolder();
    final key = RecoveryKey.create();
    await _publish(folder, key, secret);
    await _setVerifier(await key.verifier());
    return key;
  }

  /// A new recovery key: the old one stops opening the bootstrap file and stops being able to enrol devices. (It does not change the
  /// secret of the profile: someone who already signed in with the old key has it.)
  Future<RecoveryKey> regenerate() async {
    if (!enabled) throw StateError(tr('Signing in is not on.'));
    final folder = _needFolder();
    final key = RecoveryKey.create();
    await _publish(folder, key, _devices.profileSecret!);
    await _setVerifier(await key.verifier());
    return key;
  }

  /// Turns signing in off: the bootstrap file and the endorsements are taken out of the folder. The files go first and the setting
  /// after, so that a folder that cannot be reached (or a delete that fails half way) leaves signing in *on*, to be turned off again:
  /// the other way round, the screen would say "off" while the recovery key still opened the profile's secret in the folder.
  Future<void> disable() async {
    final folder = _needFolder();
    await folder.delete(bootstrapPath);
    for (final name in await folder.list(dir)) {
      if (name.startsWith('j-')) await folder.delete('$dir/$name');
    }
    await _setVerifier(null);
  }

  Future<void> _setVerifier(Uint8List? v) async {
    _verifier = v;
    await _settings.set(kVerifier, v == null ? '' : base64.encode(v));
    _seen = {};
    await _settings.set(_kSeen, '[]');
    notifyListeners();
    _devices.onSettingsChanged?.call();
  }

  // ---- taking in the devices that signed in

  /// Looks in the folder for devices that signed in with the recovery key since the last look, and adds them to the list of devices
  /// when their endorsement is signed with the key this profile expects. Called with every run of the sync through the folder. Returns
  /// how many devices came.
  Future<int> admit(CloudFolder folder) async {
    final verifier = _verifier, secret = _devices.profileSecret;
    if (verifier == null || secret == null) return 0;
    var added = 0;
    final names = [for (final n in await folder.list(dir)) if (n.startsWith('j-')) n];
    for (final name in names) {
      if (_seen.contains(name)) continue;
      final path = '$dir/$name';
      final raw = await folder.read(path);
      if (raw == null) continue;
      final Endorsement? e;
      try {
        e = Endorsement.fromBytes(await openApart(secret.cloudKey, raw, aad: placeOf(path)));
      } catch (err) {
        syncDiag('admit: $name could not be opened ($err)');
        continue; // not sealed with the key of this profile
      }
      if (e == null || !await e.verify(verifier)) {
        syncDiag('admit: $name is ${e == null ? 'unreadable' : '${e.id} (${e.name}) but NOT signed with the recovery key this profile expects'}');
        continue; // not signed with the recovery key: not a device somebody vouched for
      }
      _seen.add(name);
      // a device that is known stays as it is (a removal stays too), unless it signed in again after it was removed
      final merged = await _devices.book.merge([e.device]);
      syncDiag('admit: ${e.id} (${e.name}) key ${keyTag(e.publicKey)} from $name: ${merged ? 'added or updated' : 'nothing changed (already known, or another key is on the list)'}');
      if (!merged) continue;
      _via[e.id] = DateTime.now().millisecondsSinceEpoch;
      added++;
    }
    if (names.isNotEmpty || _seen.isNotEmpty) {
      await _settings.set(_kSeen, jsonEncode(_seen.toList()));
      if (added > 0) await _settings.set(_kVia, jsonEncode(_via));
    }
    if (added > 0) {
      _devices.refreshPeers();
      notifyListeners();
    }
    return added;
  }

  // ---- signing in on a new device

  /// Signs in: reads the bootstrap file in [folder], opens it with [keyText], makes this device part of the profile (taking over its
  /// secret, id and name), vouches for it in the folder, and learns who else is in from the folder. The caller makes the sync through
  /// the folder run afterwards (see [CloudSyncService.adoptSignIn]).
  Future<SignInProfile> signIn(CloudFolder folder, String keyText) async {
    final key = RecoveryKey.parse(keyText);
    if (key == null) throw StateError(tr('That is not a recovery key. It has 25 letters and digits, like ABCDE-FGHJK-MNPQR-STUVW-XY234.'));
    final raw = await folder.read(bootstrapPath);
    if (raw == null) {
      throw StateError(tr('Nothing to sign in to was found in this folder. Is signing in turned on on your other device, and is the folder name the same?'));
    }
    final profile = await SignInFile.open(raw, key);
    syncDiag('sign-in: opened the sign-in file, profile ${profile.profileId}, server ${profile.server.isEmpty ? '(none)' : profile.server}');
    final me = await _devices.joinWithSecret(profile.secret, profile.profileId, profile.profileName, server: profile.server);
    // the devices that were part of the profile when the key was made, and the ones that signed in since: each has an endorsement
    final self = _devices.book.find(me.id)!;
    await _writeEndorsement(folder, profile.secret, await Endorsement.make(key, self));
    final seeded = await _readEndorsed(folder, profile.secret, profile.verifier);
    syncDiag('sign-in: ${me.id} learned ${seeded.length} endorsed devices: ${seeded.map((d) => '${d.id}(${d.name},${keyTag(d.publicKey)})').join(' ')}');
    await _devices.book.merge(seeded);
    syncDiag('sign-in: the list is now ${_devices.book.describe()}');
    await _settings.set(kVerifier, base64.encode(profile.verifier));
    await load();
    return profile;
  }

  Future<List<PairedDevice>> _readEndorsed(CloudFolder folder, SyncSecret secret, Uint8List verifier) async {
    final out = <PairedDevice>[];
    for (final name in await folder.list(dir)) {
      if (!name.startsWith('j-')) continue;
      final path = '$dir/$name';
      final raw = await folder.read(path);
      if (raw == null) continue;
      try {
        final e = Endorsement.fromBytes(await openApart(secret.cloudKey, raw, aad: placeOf(path)));
        final ok = e != null && await e.verify(verifier);
        syncDiag('sign-in: endorsement $name: ${e == null ? 'unreadable' : '${e.id} (${e.name}) key ${keyTag(e.publicKey)} at ${e.at}, ${ok ? 'signed with the recovery key' : 'NOT signed with the recovery key'}'}');
        if (e != null && ok) out.add(e.device);
      } catch (e) {
        syncDiag('sign-in: endorsement $name could not be opened ($e)');
      }
    }
    return out;
  }

  /// The devices to read the lists of others from after signing in: removals found in any of the devices' own lists win over the
  /// endorsements (an endorsement stays in the folder after the device was removed), and a device that another one lists as removed is
  /// not believed about who else is in.
  static Future<void> learnRemovals(FolderSync sync, DeviceBook book) async {
    final lists = <String, List<PairedDevice>>{};
    for (final d in book.active) {
      if (d.id == sync.deviceId) continue;
      final l = await sync.deviceListOf(d.id);
      syncDiag('learnRemovals: list of ${d.id} (${d.name}): ${l == null ? 'none found' : l.map((x) => '${x.id}(${keyTag(x.publicKey)}${x.active ? '' : ',removed'})').join(' ')}');
      if (l != null) lists[d.id] = l;
    }
    final removed = <String>{};
    for (final e in lists.entries) {
      for (final d in e.value) {
        if (d.id != e.key && !d.active) removed.add(d.id);
      }
    }
    for (final e in lists.entries) {
      if (removed.contains(e.key)) continue; // (a removed device is not asked who else is in)
      await book.merge(e.value);
    }
  }
}
