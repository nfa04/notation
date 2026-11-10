import 'dart:convert';
import 'dart:ui';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Non-secret app settings, as strings. Secrets (passwords) do not belong
/// here: they go into the platform keystore.
class SettingsRepository {
  final Database _db;

  SettingsRepository(this._db);

  Future<String?> get(String key) async {
    final rows = await _db.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  Future<void> set(String key, String value) => _db.insert(
        'settings',
        {'key': key, 'value': value, 'changed_at': DateTime.now().millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  /// A value that came from another device, with the time it was set there.
  Future<void> setFromSync(String key, String value, int changedAt) =>
      _db.insert('settings', {'key': key, 'value': value, 'changed_at': changedAt}, conflictAlgorithm: ConflictAlgorithm.replace);

  /// The value of every key with the time it was set, for those that [include] (the settings that sync between devices).
  Future<Map<String, ({String value, int changedAt})>> allWhere(bool Function(String key) include) async {
    final rows = await _db.query('settings');
    return {
      for (final r in rows)
        if (include(r['key'] as String)) r['key'] as String: (value: r['value'] as String, changedAt: (r['changed_at'] as int?) ?? 0),
    };
  }

  Future<void> remove(String key) => _db.delete('settings', where: 'key = ?', whereArgs: [key]);

  /// Pen colours the user added to the palette (most recent last).
  Future<List<Color>> penColors() async {
    final rows = await _db.query('settings', where: 'key = ?', whereArgs: ['pen_colors']);
    if (rows.isEmpty) return [];
    return [for (final v in jsonDecode(rows.single['value'] as String) as List) Color(v as int)];
  }

  Future<void> setPenColors(List<Color> colors) => set('pen_colors', jsonEncode([for (final c in colors) c.toARGB32()]));
}
