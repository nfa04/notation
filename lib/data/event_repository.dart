import 'dart:async';
import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'note_repository.dart';

/// One of the app's own calendars.
class LocalCalendar {
  final String id;
  final String name;
  final int? color;
  final bool hidden;
  final int sortOrder;
  final int updatedAt;

  const LocalCalendar({required this.id, required this.name, this.color, this.hidden = false, this.sortOrder = 0, this.updatedAt = 0});
}

/// An event in one of the app's own calendars.
class LocalEvent {
  final String id;
  final String calendarId;
  final String title;
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String? tz;
  final String? location;
  final String? url;
  final String? notes;

  /// RRULE value without the `RRULE:` prefix; null for a single event.
  final String? rrule;

  /// Occurrences (by their original start) that were deleted.
  final List<DateTime> exdates;

  /// Single occurrences that were edited, keyed by their original start in UTC ms.
  final Map<int, Map<String, Object?>> overrides;

  /// Minutes before the start at which to remind.
  final List<int> alarms;

  /// Email addresses of the people invited (kept with the event; the app sends no invitations).
  final List<String> attendees;
  final int updatedAt;

  const LocalEvent({
    required this.id,
    required this.calendarId,
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
    this.tz,
    this.location,
    this.url,
    this.notes,
    this.rrule,
    this.exdates = const [],
    this.overrides = const {},
    this.alarms = const [],
    this.attendees = const [],
    this.updatedAt = 0,
  });

  bool get repeats => rrule != null && rrule!.isNotEmpty;

  LocalEvent copyWith({
    String? calendarId,
    String? title,
    DateTime? start,
    DateTime? end,
    bool? allDay,
    Object? location = _keep,
    Object? url = _keep,
    Object? notes = _keep,
    Object? rrule = _keep,
    List<DateTime>? exdates,
    Map<int, Map<String, Object?>>? overrides,
    List<int>? alarms,
    List<String>? attendees,
  }) =>
      LocalEvent(
        id: id,
        calendarId: calendarId ?? this.calendarId,
        title: title ?? this.title,
        start: start ?? this.start,
        end: end ?? this.end,
        allDay: allDay ?? this.allDay,
        tz: tz,
        location: identical(location, _keep) ? this.location : location as String?,
        url: identical(url, _keep) ? this.url : url as String?,
        notes: identical(notes, _keep) ? this.notes : notes as String?,
        rrule: identical(rrule, _keep) ? this.rrule : rrule as String?,
        exdates: exdates ?? this.exdates,
        overrides: overrides ?? this.overrides,
        alarms: alarms ?? this.alarms,
        attendees: attendees ?? this.attendees,
        updatedAt: updatedAt,
      );
}

const Object _keep = Object();

/// The app's own calendars and their events (the ones that are not on a CalDAV server or the phone).
class EventRepository {
  final Database _db;

  EventRepository(this._db);

  final _changes = StreamController<void>.broadcast();

  /// Fires after a calendar or an event was made, changed or deleted, or came from another device.
  Stream<void> get changes => _changes.stream;
  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static int _ms(DateTime t) => t.toUtc().millisecondsSinceEpoch;
  static DateTime _time(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

  static LocalCalendar _calendar(Map<String, Object?> r) => LocalCalendar(
        id: r['id'] as String,
        name: r['name'] as String,
        color: r['color'] as int?,
        hidden: r['hidden'] == 1,
        sortOrder: r['sort_order'] as int? ?? 0,
        updatedAt: r['updated_at'] as int? ?? 0,
      );

  static LocalEvent _event(Map<String, Object?> r) {
    List<T> list<T>(Object? json) => json == null ? <T>[] : (jsonDecode(json as String) as List).cast<T>();
    final raw = r['overrides'] == null ? <String, dynamic>{} : jsonDecode(r['overrides'] as String) as Map<String, dynamic>;
    return LocalEvent(
      id: r['id'] as String,
      calendarId: r['calendar_id'] as String,
      title: r['title'] as String,
      start: _time(r['start_at'] as int),
      end: _time(r['end_at'] as int),
      allDay: r['all_day'] == 1,
      tz: r['tz'] as String?,
      location: r['location'] as String?,
      url: r['url'] as String?,
      notes: r['notes'] as String?,
      rrule: r['rrule'] as String?,
      exdates: [for (final ms in list<int>(r['exdates'])) _time(ms)],
      overrides: {for (final e in raw.entries) int.parse(e.key): Map<String, Object?>.from(e.value as Map)},
      alarms: list<int>(r['alarms']),
      attendees: list<String>(r['attendees']),
      updatedAt: r['updated_at'] as int? ?? 0,
    );
  }

  static Map<String, Object?> _row(LocalEvent e, int now) => {
        'id': e.id,
        'calendar_id': e.calendarId,
        'title': e.title,
        'start_at': _ms(e.start),
        'end_at': _ms(e.end),
        'all_day': e.allDay ? 1 : 0,
        'tz': e.tz,
        'location': e.location,
        'url': e.url,
        'notes': e.notes,
        'rrule': e.rrule,
        'exdates': e.exdates.isEmpty ? null : jsonEncode([for (final d in e.exdates) _ms(d)]),
        'overrides': e.overrides.isEmpty ? null : jsonEncode({for (final o in e.overrides.entries) '${o.key}': o.value}),
        'alarms': e.alarms.isEmpty ? null : jsonEncode(e.alarms),
        'attendees': e.attendees.isEmpty ? null : jsonEncode(e.attendees),
        'updated_at': now,
        'deleted_at': null,
      };

  // ---- calendars ----

  /// The calendars in their order. The first one is made when there is none, so there is always one to put an event in.
  Future<List<LocalCalendar>> calendars() async {
    var rows = await _db.query('local_calendars', where: 'deleted_at IS NULL', orderBy: 'sort_order, name');
    if (rows.isEmpty && (await _db.query('local_calendars', limit: 1)).isEmpty) {
      await createCalendar('My calendar', id: defaultCalendarId);
      rows = await _db.query('local_calendars', where: 'deleted_at IS NULL', orderBy: 'sort_order, name');
    }
    return rows.map(_calendar).toList();
  }

  /// The same id on every device, so that "My calendar" made on two devices is one calendar after a sync.
  static const defaultCalendarId = 'my-calendar';

  Future<String> createCalendar(String name, {int? color, String? id}) async {
    id ??= NoteRepository.newId();
    final order = ((await _db.rawQuery('SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM local_calendars')).first['n'] as int?) ?? 0;
    await _db.insert(
      'local_calendars',
      {'id': id, 'name': name, 'color': color, 'sort_order': order, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _changed();
    return id;
  }

  Future<void> updateCalendar(String id, {String? name, Object? color = _keep, bool? hidden}) async {
    final values = <String, Object?>{'updated_at': DateTime.now().millisecondsSinceEpoch};
    if (name != null) values['name'] = name;
    if (!identical(color, _keep)) values['color'] = color as int?;
    if (hidden != null) values['hidden'] = hidden ? 1 : 0;
    await _db.update('local_calendars', values, where: 'id = ?', whereArgs: [id]);
    _changed();
  }

  /// Deletes the calendar with its events (kept as marks, so that the other devices delete them too).
  Future<void> deleteCalendar(String id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((t) async {
      await t.update('local_events', {'deleted_at': now, 'updated_at': now}, where: 'calendar_id = ? AND deleted_at IS NULL', whereArgs: [id]);
      await t.update('local_calendars', {'deleted_at': now, 'updated_at': now}, where: 'id = ?', whereArgs: [id]);
    });
    _changed();
  }

  // ---- events ----

  Future<String> createEvent(LocalEvent e) async {
    final id = e.id.isEmpty ? NoteRepository.newId() : e.id;
    final made = LocalEvent(
      id: id, calendarId: e.calendarId, title: e.title, start: e.start, end: e.end, allDay: e.allDay, tz: e.tz, location: e.location,
      url: e.url, notes: e.notes, rrule: e.rrule, exdates: e.exdates, overrides: e.overrides, alarms: e.alarms, attendees: e.attendees,
    );
    await _db.insert('local_events', _row(made, DateTime.now().millisecondsSinceEpoch), conflictAlgorithm: ConflictAlgorithm.replace);
    _changed();
    return id;
  }

  Future<void> updateEvent(LocalEvent e) async {
    await _db.update('local_events', _row(e, DateTime.now().millisecondsSinceEpoch), where: 'id = ?', whereArgs: [e.id]);
    _changed();
  }

  /// Kept as a mark (not removed) until every device has seen it; [purgeDeleted] cleans up later.
  Future<void> deleteEvent(String id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.update('local_events', {'deleted_at': now, 'updated_at': now}, where: 'id = ?', whereArgs: [id]);
    _changed();
  }

  Future<LocalEvent?> event(String id) async {
    final rows = await _db.query('local_events', where: 'id = ? AND deleted_at IS NULL', whereArgs: [id]);
    return rows.isEmpty ? null : _event(rows.first);
  }

  /// The events that may show in [from, to): single ones overlapping it and every repeating one that has started
  /// before [to] (the caller expands the repetitions). Events of hidden calendars are left out.
  Future<List<LocalEvent>> eventsIn(DateTime from, DateTime to) async {
    final rows = await _db.rawQuery('''
      SELECT e.* FROM local_events e
      JOIN local_calendars c ON c.id = e.calendar_id AND c.deleted_at IS NULL AND c.hidden = 0
      WHERE e.deleted_at IS NULL
        AND e.start_at < ?
        AND (e.end_at > ? OR (e.rrule IS NOT NULL AND e.rrule <> ''))
      ORDER BY e.start_at
    ''', [_ms(to), _ms(from)]);
    return rows.map(_event).toList();
  }

  /// Events whose title contains [text] (case-insensitive), soonest first.
  Future<List<LocalEvent>> search(String text, {int limit = 50}) async {
    final like = '%${text.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
    final rows = await _db.query(
      'local_events',
      where: "deleted_at IS NULL AND (title LIKE ? ESCAPE '\\' OR location LIKE ? ESCAPE '\\' OR notes LIKE ? ESCAPE '\\')",
      whereArgs: [like, like, like],
      orderBy: 'start_at DESC',
      limit: limit,
    );
    return rows.map(_event).toList();
  }

  /// Forgets marks older than [olderThan] (a device that was away longer than that gets them back as new events).
  Future<void> purgeDeleted({Duration olderThan = const Duration(days: 90)}) async {
    final cutoff = DateTime.now().subtract(olderThan).millisecondsSinceEpoch;
    await _db.delete('local_events', where: 'deleted_at IS NOT NULL AND deleted_at < ?', whereArgs: [cutoff]);
    await _db.delete('local_calendars', where: 'deleted_at IS NOT NULL AND deleted_at < ?', whereArgs: [cutoff]);
  }
}
