import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../data/app_secure_storage.dart';
import 'sync_diag.dart';

/// A device that is part of the profile: the other devices accept it because its public key is on their list, and it proves it
/// owns the matching private key (its *device secret*) each time it connects.
class PairedDevice {
  final String id;
  final String name;
  final Uint8List publicKey;

  /// When it was added to the profile (ms since the epoch).
  final int addedAt;

  /// When it was taken out of the profile, if it was. A device that is put back later has a later [addedAt].
  final int? removedAt;

  /// When the device was given its [name] (0: when it was added): of two names for one device, the later one is its name.
  final int namedAt;

  const PairedDevice({required this.id, required this.name, required this.publicKey, required this.addedAt, this.removedAt, this.namedAt = 0});

  bool get active => removedAt == null || addedAt > removedAt!;

  PairedDevice removed(int at) => PairedDevice(id: id, name: name, publicKey: publicKey, addedAt: addedAt, removedAt: at, namedAt: namedAt);

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'key': base64.encode(publicKey),
        'added': addedAt,
        if (removedAt != null) 'removed': removedAt,
        if (namedAt != 0) 'named': namedAt,
      };

  static PairedDevice? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'], key = j['key'], added = j['added'];
    if (id is! String || name is! String || key is! String || added is! int) return null;
    try {
      final bytes = base64.decode(key);
      if (bytes.length != 32) return null;
      return PairedDevice(id: id, name: name, publicKey: Uint8List.fromList(bytes), addedAt: added, removedAt: j['removed'] as int?, namedAt: j['named'] is int ? j['named'] as int : 0);
    } on FormatException {
      return null;
    }
  }
}

/// The devices of the profile, as this device knows them. It is kept in the settings and is itself synced: a device that joins is
/// told of the others by the one that let it in, and the others hear of it at their next sync.
class DeviceBook {
  static const settingKey = 'sync_devices';

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;

  DeviceBook(this._read, this._write);

  final Map<String, PairedDevice> _devices = {};

  /// Everything on the list, also devices that were removed (the removal is told to the others).
  List<PairedDevice> get all => List.unmodifiable(_devices.values);

  /// The devices that are part of the profile.
  List<PairedDevice> get active => [for (final d in _devices.values) if (d.active) d];

  PairedDevice? find(String id) {
    final d = _devices[id];
    return d != null && d.active ? d : null;
  }

  Future<void> load() async {
    _devices.clear();
    final text = await _read(settingKey);
    if (text == null) return;
    try {
      for (final j in jsonDecode(text) as List) {
        final d = PairedDevice.fromJson(j);
        if (d != null) _devices[d.id] = d;
      }
      syncDiag('book loaded: ${describe()}');
    } on FormatException {
      syncDiag('book unreadable, treated as empty');
      // an unreadable list is an empty one: the devices are paired again
    }
  }

  Future<void> _save() => _write(settingKey, jsonEncode([for (final d in _devices.values) d.toJson()]));

  /// One line with every device on the list: id, name, start of the key, active or removed.
  String describe() => [
    for (final d in _devices.values)
      '${d.id}(${d.name},${keyTag(d.publicKey)},${d.active ? 'on' : 'removed'})',
  ].join(' ');

  Future<void> add(PairedDevice device) async {
    final old = _devices[device.id];
    syncDiag(
      'book add ${device.id} (${device.name}) key ${keyTag(device.publicKey)}${old == null
          ? ''
          : old.publicKey.length == device.publicKey.length && _same(old.publicKey, device.publicKey)
          ? ' (same key as before)'
          : ' REPLACES key ${keyTag(old.publicKey)}'}',
    );
    _devices[device.id] = device;
    await _save();
  }

  Future<void> remove(String id, int at) async {
    final d = _devices[id];
    if (d == null) return;
    syncDiag('book remove $id (${d.name})');
    _devices[id] = d.removed(at);
    await _save();
  }

  /// The device [id] has a new name (given at [at]): the others take it at the next merge of the lists.
  Future<void> rename(String id, String name, int at) async {
    final d = _devices[id];
    if (d == null || d.name == name) return;
    _devices[id] = PairedDevice(id: d.id, name: name, publicKey: d.publicKey, addedAt: d.addedAt, removedAt: d.removedAt, namedAt: at);
    await _save();
  }

  Future<void> clear() async {
    syncDiag('book cleared (had: ${describe()})');
    _devices.clear();
    await _save();
  }

  /// Takes in the list of another device of the profile: a device it knows of that this one does not is added, a removal that is
  /// later than the addition is followed. Returns whether anything changed.
  Future<bool> merge(Iterable<PairedDevice> theirs) async {
    var changed = false;
    for (final t in theirs) {
      final mine = _devices[t.id];
      if (mine == null) {
        syncDiag(
          'book merge: new ${t.id} (${t.name}) key ${keyTag(t.publicKey)}',
        );
        _devices[t.id] = t;
        changed = true;
      } else if (mine.publicKey.length == t.publicKey.length && _same(mine.publicKey, t.publicKey)) {
        final newer = t.addedAt > mine.addedAt || (t.removedAt ?? 0) > (mine.removedAt ?? 0) || t.namedAt > mine.namedAt;
        if (newer) {
          final renamed = t.namedAt > mine.namedAt;
          _devices[t.id] = PairedDevice(
            id: t.id,
            name: renamed ? t.name : mine.name,
            publicKey: t.publicKey,
            addedAt: t.addedAt > mine.addedAt ? t.addedAt : mine.addedAt,
            removedAt: (t.removedAt ?? 0) > (mine.removedAt ?? 0) ? t.removedAt : mine.removedAt,
            namedAt: renamed ? t.namedAt : mine.namedAt,
          );
          changed = true;
        }
      } else {
        syncDiag(
          'book merge: NOT taking ${t.id} (${t.name}): key ${keyTag(t.publicKey)} offered, key ${keyTag(mine.publicKey)} is the one on the list',
        );
      }
      // another key under a known id is not taken over: the id is already someone's
    }
    if (changed) await _save();
    return changed;
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Where the two secrets of this device are kept: the secret of the profile and the device secret. Both stay on the device, in
/// the secure storage of the system.
abstract class SyncKeyStore {
  Future<Uint8List?> profileSecret();
  Future<void> setProfileSecret(Uint8List? value);
  Future<Uint8List?> deviceSeed();
  Future<void> setDeviceSeed(Uint8List? value);

  /// Who this device is: its id and its secret half together, in ONE entry. (They used to be kept in two places - the seed here,
  /// the id in the settings - and a write that got lost in one of them left an id that another device had accepted with a key that
  /// was not the one it had accepted: every meeting was then refused, for ever.)
  Future<({String id, Uint8List seed})?> deviceIdentity();
  Future<void> setDeviceIdentity(({String id, Uint8List seed})? value);
}

class KeystoreSyncKeys implements SyncKeyStore {
  final FlutterSecureStorage _storage;

  const KeystoreSyncKeys([this._storage = appSecureStorage]);

  /// An entry the keystore cannot open (the browser's one throws when what was written with another key is read) is an absent one: the
  /// device then makes a new identity, and the write replaces the broken entry.
  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      syncDiag('keystore: $key cannot be read ($e); treated as absent');
      return null;
    }
  }

  Future<Uint8List?> _get(String key) async {
    final v = await _read( key);
    if (v == null) return null;
    try {
      return Uint8List.fromList(base64.decode(v));
    } on FormatException {
      return null;
    }
  }

  Future<void> _put(String key, Uint8List? value) =>
      value == null ? _storage.delete(key: key) : _storage.write(key: key, value: base64.encode(value));

  @override
  Future<Uint8List?> profileSecret() => _get('sync_profile_secret');

  @override
  Future<void> setProfileSecret(Uint8List? value) => _put('sync_profile_secret', value);

  @override
  Future<Uint8List?> deviceSeed() => _get('sync_device_seed');

  @override
  Future<void> setDeviceSeed(Uint8List? value) => _put('sync_device_seed', value);

  @override
  Future<({String id, Uint8List seed})?> deviceIdentity() async {
    final v = await _read('sync_device_identity');
    final dot = v?.indexOf('.') ?? -1;
    if (v == null || dot <= 0) return null;
    try {
      return (
        id: v.substring(0, dot),
        seed: Uint8List.fromList(base64.decode(v.substring(dot + 1))),
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> setDeviceIdentity(({String id, Uint8List seed})? value) =>
      value == null
      ? _storage.delete(key: 'sync_device_identity')
      : _storage.write(
          key: 'sync_device_identity',
          value: '${value.id}.${base64.encode(value.seed)}',
        );
}

/// For tests: the same in memory.
class MemorySyncKeys implements SyncKeyStore {
  Uint8List? _secret, _seed;

  @override
  Future<Uint8List?> profileSecret() async => _secret;

  @override
  Future<void> setProfileSecret(Uint8List? value) async => _secret = value;

  @override
  Future<Uint8List?> deviceSeed() async => _seed;

  @override
  Future<void> setDeviceSeed(Uint8List? value) async => _seed = value;

  ({String id, Uint8List seed
})? _identity;

  @override
  Future<({String id, Uint8List seed})?> deviceIdentity() async => _identity;

  @override
  Future<void> setDeviceIdentity(({String id, Uint8List seed})? value) async =>
      _identity = value;
}
