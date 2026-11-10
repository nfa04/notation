import 'package:caldav/caldav.dart';

import 'task_sync.dart';

/// The day a to-do is due, as the user sees it.
DateTime? dueDayOf(CalendarTodo t) {
  final d = t.due;
  if (d == null) return null;
  // all-day dues are plain dates (kept as UTC midnight); timed ones are moments
  final day = t.isAllDay ? d : d.toLocal();
  return DateTime(day.year, day.month, day.day);
}

/// One server calendar's to-dos, for [syncTasks].
class CalDavRemoteTodos implements RemoteTodos {
  final CalDavClient client;
  final Calendar calendar;

  CalDavRemoteTodos(this.client, this.calendar);

  static RemoteTodo _remote(CalendarTodo t) => RemoteTodo(
        uid: t.uid,
        href: t.href.toString(),
        etag: t.etag,
        title: t.summary,
        dueDate: dueDayOf(t),
        done: t.isCompleted,
        handle: t,
      );

  @override
  Future<List<RemoteTodo>> list() async => [
        for (final t in await client.getTodos(calendar))
          // a modified single occurrence of a repeating to-do is not a task of its own
          if (t.recurrenceId == null) _remote(t),
      ];

  @override
  Future<RemoteTodo> create(String uid, TodoFields f) async {
    final due = f.dueDate;
    final created = await client.createTodo(
      calendar,
      CalendarTodo(
        uid: uid,
        calendarId: calendar.uid,
        summary: f.title,
        due: due == null ? null : DateTime.utc(due.year, due.month, due.day),
        isAllDay: due != null,
        status: f.done ? TodoStatus.completed : TodoStatus.needsAction,
        percentComplete: f.done ? 100 : null,
        completed: f.done ? DateTime.now().toUtc() : null,
      ),
    );
    return _remote(created);
  }

  /// Writes only what this app edits and keeps the rest of the to-do (notes,
  /// priority, repeat rule). Properties the library does not model, like
  /// sub-task links or alarms, are not preserved by it.
  @override
  Future<RemoteTodo> update(RemoteTodo existing, TodoFields f) async {
    final base = existing.handle as CalendarTodo;
    final due = f.dueDate;
    final dueChanged = due != dueDayOf(base);

    final updated = await client.updateTodo(CalendarTodo(
      uid: base.uid,
      calendarId: base.calendarId,
      href: base.href,
      etag: base.etag,
      summary: f.title,
      description: base.description,
      location: base.location,
      // an unchanged due date keeps its original time; a changed one is a plain date
      dtstart: dueChanged ? null : base.dtstart,
      due: !dueChanged ? base.due : (due == null ? null : DateTime.utc(due.year, due.month, due.day)),
      isAllDay: dueChanged ? due != null : base.isAllDay,
      status: f.done ? TodoStatus.completed : (base.status == TodoStatus.completed ? TodoStatus.needsAction : base.status),
      completed: f.done ? (base.completed ?? DateTime.now().toUtc()) : null,
      percentComplete: f.done ? 100 : (base.percentComplete == 100 ? null : base.percentComplete),
      priority: base.priority,
      rrule: base.rrule,
      recurrenceId: base.recurrenceId,
      exdate: base.exdate,
      isReadOnly: base.isReadOnly,
    ));
    return _remote(updated);
  }

  @override
  Future<void> delete(RemoteTodo existing) => client.deleteTodo(existing.handle as CalendarTodo);
}

/// A calendar, as far as looks are concerned.
class CalendarInfo {
  /// Same as [DayEvent.calendarKey].
  final String key;
  final String name;
  final String? color;

  /// Events cannot be added to it.
  final bool readOnly;

  const CalendarInfo(this.key, this.name, this.color, {this.readOnly = false});
}

/// An event the person makes (see `CalDavService.createEvent`).
class NewEvent {
  final String title;

  /// Local time; for an all-day event the first day.
  final DateTime start;

  /// Local time; for an all-day event the last day (inclusive); null: a single day, or no end.
  final DateTime? end;
  final bool allDay;
  final String description;

  const NewEvent({required this.title, required this.start, this.end, this.allDay = false, this.description = ''});
}

/// An event of a server calendar, for display.
class DayEvent {
  final String title;
  final DateTime start; // local time
  final DateTime? end; // local time; for all-day events the last day (inclusive)
  final bool allDay;
  final String calendarName;
  final String? color;
  final bool repeats;

  /// Which calendar and event this is, for looks the user attached to them
  /// (empty when unknown). The calendar key is the calendar's address on the
  /// server, or `phone:<id>` for a phone calendar.
  final String calendarKey;
  final String uid;

  const DayEvent({
    required this.title,
    required this.start,
    this.end,
    required this.allDay,
    required this.calendarName,
    this.color,
    this.repeats = false,
    this.calendarKey = '',
    this.uid = '',
  });

  Map<String, Object?> toJson() => {
        't': title,
        's': start.millisecondsSinceEpoch,
        'e': end?.millisecondsSinceEpoch,
        'a': allDay,
        'n': calendarName,
        'c': color,
        'r': repeats,
        'k': calendarKey,
        'u': uid,
      };

  static DayEvent fromJson(Map<String, Object?> j) => DayEvent(
        title: j['t'] as String,
        start: DateTime.fromMillisecondsSinceEpoch(j['s'] as int),
        end: j['e'] == null ? null : DateTime.fromMillisecondsSinceEpoch(j['e'] as int),
        allDay: j['a'] as bool,
        calendarName: j['n'] as String,
        color: j['c'] as String?,
        repeats: j['r'] as bool,
        calendarKey: j['k'] as String,
        uid: j['u'] as String,
      );

  static DayEvent from(CalendarEvent e, Calendar calendar) {
    // all-day events are plain dates (UTC midnight): do not shift them by the time zone
    DateTime conv(DateTime d) => e.isAllDay ? DateTime(d.year, d.month, d.day) : d.toLocal();
    return DayEvent(
      title: e.summary,
      start: conv(e.start),
      end: e.end == null ? null : conv(e.end!),
      allDay: e.isAllDay,
      calendarName: calendar.displayName,
      color: calendar.color,
      repeats: e.rrule != null,
      calendarKey: calendar.href.toString(),
      uid: e.uid,
    );
  }

  /// Whether the event is on [day] (a date without time).
  bool occursOn(DateTime day) {
    final first = DateTime(start.year, start.month, start.day);
    final lastSource = end ?? start;
    var last = DateTime(lastSource.year, lastSource.month, lastSource.day);
    // a timed event ending exactly at midnight does not reach into that day
    if (!allDay && end != null && end!.hour == 0 && end!.minute == 0 && last.isAfter(first)) {
      last = DateTime(last.year, last.month, last.day - 1);
    }
    return !day.isBefore(first) && !day.isAfter(last);
  }
}
