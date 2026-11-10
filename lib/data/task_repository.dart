import 'dart:async';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'note_repository.dart';

/// A calendar day without a time; the time part is always zero.
DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

String _dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _parseDay(String key) {
  final p = key.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

/// A to-do with an optional due date; it can be put on a calendar as an event (see `TaskCalendarMirror`).
class Task {
  final String id;
  final String title;
  final DateTime? dueDate;
  final bool done;

  /// When it was ticked off; null while it is open (and for a task done on a device that did not say when).
  final DateTime? doneAt;

  /// Made by an automation or found in a note (not typed in).
  final bool auto;

  const Task({required this.id, required this.title, this.dueDate, this.done = false, this.doneAt, this.auto = false});
}

/// A task together with what the sync needs to know about it.
class SyncTask extends Task {
  /// Where it lives on the CalDAV server and its version there as of the last
  /// sync; null until it was uploaded once.
  final String? remoteHref;
  final String? remoteEtag;

  /// Changed here since the last sync.
  final bool dirty;

  /// Deleted here, but not yet on the server.
  final bool deleted;

  const SyncTask({
    required super.id,
    required super.title,
    super.dueDate,
    super.done,
    super.auto,
    this.remoteHref,
    this.remoteEtag,
    this.dirty = false,
    this.deleted = false,
  });
}

/// The 42 days (six Monday-first weeks) shown for [month]'s grid.
List<DateTime> monthGrid(DateTime month) {
  final first = DateTime(month.year, month.month, 1);
  final start = first.subtract(Duration(days: first.weekday - 1));
  // calendar arithmetic instead of adding Durations: days are not always 24h
  return [for (var i = 0; i < 42; i++) DateTime(start.year, start.month, start.day + i)];
}

/// Tasks, and the calendar data kept beside them in the database: the cache of events read from CalDAV and which
/// task became which event.
class TaskRepository {
  final Database _db;

  TaskRepository(this._db);

  final _changes = StreamController<void>.broadcast();

  /// Fires after a task was made, changed, done or deleted (or came from the server).
  Stream<void> get changes => _changes.stream;
  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static Task _task(Map<String, Object?> r) => Task(
        id: r['id'] as String,
        title: r['title'] as String,
        dueDate: r['due_date'] == null ? null : _parseDay(r['due_date'] as String),
        done: r['done_at'] != null,
        doneAt: r['done_at'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['done_at'] as int),
        auto: r['auto'] == 1,
      );

  /// Open tasks first, then by due date (undated last), then oldest first.
  Future<List<Task>> listTasks() async {
    final rows = await _db.query('tasks', where: 'deleted_at IS NULL', orderBy: '''
      done_at IS NOT NULL, due_date IS NULL, due_date, created_at
    ''');
    return rows.map(_task).toList();
  }

  Future<String> createTask(String title, {DateTime? dueDate, bool auto = false}) async {
    final id = NoteRepository.newId();
    await _db.insert('tasks', {
      'id': id,
      'title': title,
      'due_date': dueDate == null ? null : _dayKey(dueDate),
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'dirty': 1,
      'auto': auto ? 1 : 0,
    });
    _changed();
    return id;
  }

  /// Replaces title and due date (null = no date).
  Future<void> updateTask(String id, {required String title, DateTime? dueDate}) async {
    await _db.update(
      'tasks',
      {'title': title, 'due_date': dueDate == null ? null : _dayKey(dueDate), 'dirty': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
    _changed();
  }

  final _completed = StreamController<Task>.broadcast();

  /// The tasks as they are ticked off here (not the ones that arrive from the server done).
  Stream<Task> get completed => _completed.stream;

  Future<void> setDone(String id, bool done) async {
    final was = done ? (await _db.query('tasks', where: 'id = ? AND done_at IS NULL AND deleted_at IS NULL', whereArgs: [id])).map(_task).firstOrNull : null;
    await _db.update(
      'tasks',
      {'done_at': done ? DateTime.now().millisecondsSinceEpoch : null, 'dirty': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
    _changed();
    if (was != null && !_completed.isClosed) _completed.add(Task(id: was.id, title: was.title, dueDate: was.dueDate, done: true, doneAt: DateTime.now(), auto: was.auto));
  }

  /// A task that was uploaded before is only marked deleted, until the next
  /// sync has deleted it on the server too; one that never was is just removed.
  Future<void> deleteTask(String id) async {
    final removed = await _db.delete('tasks', where: 'id = ? AND remote_href IS NULL', whereArgs: [id]);
    if (removed == 0) {
      await _db.update(
        'tasks',
        {'deleted_at': DateTime.now().millisecondsSinceEpoch, 'dirty': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    _changed();
  }

  // ---- events kept from the server (see CalDavService.events)

  /// What [source] answered for the days [rangeKey], and when; null if nothing was kept.
  Future<({DateTime fetched, String payload})?> cachedEvents(String source, String rangeKey) async {
    final rows = await _db.query('event_cache', where: 'source = ? AND range_key = ?', whereArgs: [source, rangeKey]);
    if (rows.isEmpty) return null;
    return (fetched: DateTime.fromMillisecondsSinceEpoch(rows.single['fetched_at'] as int), payload: rows.single['payload'] as String);
  }

  Future<void> cacheEvents(String source, String rangeKey, String payload) => _db.insert(
        'event_cache',
        {'source': source, 'range_key': rangeKey, 'fetched_at': DateTime.now().millisecondsSinceEpoch, 'payload': payload},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> clearEventCache([String? source]) =>
      _db.delete('event_cache', where: source == null ? null : 'source = ?', whereArgs: source == null ? null : [source]);

  // ---- tasks on a calendar as events (see TaskCalendarMirror)

  Future<Map<String, ({String target, String remoteId, String fingerprint})>> taskEvents() async => {
        for (final r in await _db.query('task_events'))
          r['task_id'] as String: (target: r['target'] as String, remoteId: r['remote_id'] as String, fingerprint: r['fingerprint'] as String),
      };

  Future<void> putTaskEvent(String taskId, String target, String remoteId, String fingerprint) => _db.insert(
        'task_events',
        {'task_id': taskId, 'target': target, 'remote_id': remoteId, 'fingerprint': fingerprint},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> removeTaskEvent(String taskId) => _db.delete('task_events', where: 'task_id = ?', whereArgs: [taskId]);

  // ---- sync ----------------------------------------------------------------

  /// Every task, including those deleted here and not yet on the server.
  Future<List<SyncTask>> listForSync() async {
    final rows = await _db.query('tasks');
    return [
      for (final r in rows)
        SyncTask(
          id: r['id'] as String,
          title: r['title'] as String,
          dueDate: r['due_date'] == null ? null : _parseDay(r['due_date'] as String),
          done: r['done_at'] != null,
          auto: r['auto'] == 1,
          remoteHref: r['remote_href'] as String?,
          remoteEtag: r['remote_etag'] as String?,
          dirty: r['dirty'] == 1,
          deleted: r['deleted_at'] != null,
        ),
    ];
  }

  /// The server has the current version of [id] at [href] / [etag].
  Future<void> markSynced(String id, {required String href, String? etag}) => _db.update(
        'tasks',
        {'remote_href': href, 'remote_etag': etag, 'dirty': 0},
        where: 'id = ?',
        whereArgs: [id],
      );

  /// Takes over the server's version of a task, inserting it if it is new here.
  Future<void> applyRemote({
    required String id,
    required String title,
    DateTime? dueDate,
    required bool done,
    required String href,
    String? etag,
  }) async {
    final values = {
      'title': title,
      'due_date': dueDate == null ? null : _dayKey(dueDate),
      'remote_href': href,
      'remote_etag': etag,
      'dirty': 0,
      'deleted_at': null,
    };
    final updated = await _db.update('tasks', values, where: 'id = ?', whereArgs: [id]);
    if (updated == 0) {
      await _db.insert('tasks', {...values, 'id': id, 'created_at': DateTime.now().millisecondsSinceEpoch});
    }
    // keep the original completion time when it stays done
    await _db.rawUpdate(
      done
          ? 'UPDATE tasks SET done_at = COALESCE(done_at, ?) WHERE id = ?'
          : 'UPDATE tasks SET done_at = NULL WHERE id = ?',
      done ? [DateTime.now().millisecondsSinceEpoch, id] : [id],
    );
    _changed();
  }

  /// Removes a task for good (it is gone on the server as well).
  Future<void> purge(String id) => _db.delete('tasks', where: 'id = ?', whereArgs: [id]);

  /// Forgets the server: tasks stay, but are treated as never uploaded.
  Future<void> detachFromServer() async {
    await _db.delete('tasks', where: 'deleted_at IS NOT NULL');
    await _db.update('tasks', {'remote_href': null, 'remote_etag': null, 'dirty': 1});
  }
}
