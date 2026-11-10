import 'dart:async';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../reminders/reminder.dart';
import 'note_repository.dart';

/// The reminders (table `reminders`).
class ReminderRepository {
  final Database _db;

  ReminderRepository(this._db);

  final _changes = StreamController<void>.broadcast();

  /// Fires after a reminder was made, changed or removed.
  Stream<void> get changes => _changes.stream;
  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static DateTime _time(Object? ms) => DateTime.fromMillisecondsSinceEpoch(ms as int);

  static Reminder _reminder(Map<String, Object?> r) => Reminder(
        id: r['id'] as String,
        kind: ReminderKind.values.where((k) => k.name == r['kind']).firstOrNull ?? ReminderKind.custom,
        refId: r['ref_id'] as String?,
        title: r['title'] as String,
        at: _time(r['at']),
        repeat: Repeat.byName(r['repeat'] as String?),
        auto: r['auto'] == 1,
        firedTo: r['fired_to'] == null ? null : _time(r['fired_to']),
      );

  /// Every reminder, the one that goes off first first.
  Future<List<Reminder>> all() async {
    final rows = await _db.query('reminders');
    final list = rows.map(_reminder).toList();
    list.sort((a, b) {
      final x = a.pending, y = b.pending;
      if (x == null || y == null) return x == null && y == null ? a.at.compareTo(b.at) : (x == null ? 1 : -1);
      return x.compareTo(y);
    });
    return list;
  }

  /// Makes a reminder and answers its id.
  Future<String> add({required ReminderKind kind, String? refId, required String title, required DateTime at, Repeat repeat = Repeat.none, bool auto = false}) async {
    final id = NoteRepository.newId();
    await _db.insert('reminders', {
      'id': id,
      'kind': kind.name,
      'ref_id': refId,
      'title': title,
      'at': at.millisecondsSinceEpoch,
      'repeat': repeat.name,
      'auto': auto ? 1 : 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    _changed();
    return id;
  }

  /// Changes when, how often and what it says; a reminder that moved in time is announced again.
  Future<void> update(String id, {String? title, DateTime? at, Repeat? repeat}) async {
    await _db.update(
      'reminders',
      {
        'title': ?title,
        if (at != null) 'at': at.millisecondsSinceEpoch,
        if (at != null || repeat != null) 'fired_to': null,
        if (repeat != null) 'repeat': repeat.name,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    _changed();
  }

  /// Records that the occurrence [occurrence] was announced.
  Future<void> markFired(String id, DateTime occurrence) async {
    await _db.update('reminders', {'fired_to': occurrence.millisecondsSinceEpoch}, where: 'id = ?', whereArgs: [id]);
    _changed();
  }

  Future<void> remove(String id) async {
    await _db.delete('reminders', where: 'id = ?', whereArgs: [id]);
    _changed();
  }

  /// Takes away the reminders about a note or task (it was deleted).
  Future<void> removeFor(ReminderKind kind, String refId, {bool? auto}) async {
    await _db.delete(
      'reminders',
      where: 'kind = ? AND ref_id = ?${auto == null ? '' : ' AND auto = ?'}',
      whereArgs: [kind.name, refId, if (auto != null) auto ? 1 : 0],
    );
    _changed();
  }
}
