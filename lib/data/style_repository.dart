import 'package:flutter/painting.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../style/calendar_style.dart';

/// What can carry a custom look.
enum StyleScope { calendar, event, task, day }

/// Stores the looks the user gave to calendars, events, tasks and days.
class StyleRepository {
  final Database _db;

  StyleRepository(this._db);

  /// Everything saved, by scope and key.
  Future<Map<StyleScope, Map<String, ItemStyle>>> loadAll() async {
    final all = {for (final s in StyleScope.values) s: <String, ItemStyle>{}};
    for (final r in await _db.query('styles')) {
      final scope = StyleScope.values.where((s) => s.name == r['scope']).firstOrNull;
      if (scope == null) continue; // written by a newer version
      all[scope]![r['key'] as String] = ItemStyle(
        color: r['color'] == null ? null : Color(r['color'] as int),
        border: BorderKind.byName(r['border'] as String?),
        emoji: r['emoji'] as String?,
      );
    }
    return all;
  }

  /// Saves [style]; an empty or null style removes the row.
  Future<void> save(StyleScope scope, String key, ItemStyle? style) async {
    if (style == null || style.isEmpty) {
      await _db.delete('styles', where: 'scope = ? AND key = ?', whereArgs: [scope.name, key]);
      return;
    }
    await _db.insert(
      'styles',
      {
        'scope': scope.name,
        'key': key,
        'color': style.color?.toARGB32(),
        'border': style.border?.name,
        'emoji': style.emoji == null || style.emoji!.isEmpty ? null : style.emoji,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Removes every look of one kind (for example all day stickers).
  Future<void> clearScope(StyleScope scope) => _db.delete('styles', where: 'scope = ?', whereArgs: [scope.name]);
}
