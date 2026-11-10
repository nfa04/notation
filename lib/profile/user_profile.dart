import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/authorship.dart';

/// Who uses this device: the name others see (in live sessions, in the history of a note, on what is added to a
/// note), and an id of their own. The id is made the first time the app starts and never changes, so that two
/// people who both call themselves "Ben" can still be told apart; it is not a secret and not a login.
///
/// Whether the intro was done is kept here too.
class UserProfile extends ChangeNotifier {
  /// The key of the name is the one the live settings always used, so that a name set before carries over.
  static const nameKey = 'collab_name';
  static const idKey = 'profile_id';
  static const introKey = 'intro_done';

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;
  final Random _random;

  UserProfile(this._read, this._write, {Random? random}) : _random = random ?? Random.secure();

  String _name = '';
  String _id = '';
  bool _introDone = false;
  bool _loaded = false;

  /// The name the person gave, empty if none.
  String get name => _name;

  /// 16 hex digits.
  String get id => _id;

  /// The start of the id, for telling two people of one name apart.
  String get shortId => Author.shortId(_id);

  /// Whether the intro was done (or skipped).
  bool get introDone => _introDone;

  bool get loaded => _loaded;

  /// A new id: 64 random bits as 16 hex digits.
  static String newId([Random? random]) {
    final r = random ?? Random.secure();
    return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> load() async {
    _name = ((await _read(nameKey)) ?? '').trim();
    final id = await _read(idKey);
    if (id != null && Author.isId(id)) {
      _id = id;
    } else {
      _id = newId(_random);
      await _write(idKey, _id);
    }
    _introDone = (await _read(introKey)) == '1';
    _loaded = true;
    _apply();
    notifyListeners();
  }

  void _apply() {
    Authorship.set(_name);
    Authorship.setId(_id);
  }

  /// Sets the name others see.
  Future<void> setName(String value) async {
    final v = value.trim();
    if (v == _name) return;
    _name = v;
    _apply();
    await _write(nameKey, _name);
    notifyListeners();
  }

  /// This device joins the profile of another device (see `DeviceSyncService`): it takes its id and name.
  Future<void> adopt(String id, String name) async {
    if (!Author.isId(id)) return;
    _id = id;
    _name = name.trim();
    _apply();
    await _write(idKey, _id);
    await _write(nameKey, _name);
    notifyListeners();
  }

  /// The intro is done (or the person skipped it): it does not come again by itself.
  Future<void> finishIntro() async {
    if (_introDone) return;
    _introDone = true;
    await _write(introKey, '1');
    notifyListeners();
  }

  /// Shows the intro again at the next start of the app (and now, to whoever listens).
  Future<void> resetIntro() async {
    _introDone = false;
    await _write(introKey, '0');
    notifyListeners();
  }
}
