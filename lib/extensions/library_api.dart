import '../data/task_repository.dart';
import '../reminders/reminder.dart';
import '../reminders/reminder_service.dart';
import '../sync/calendar_access.dart';
import '../sync/caldav_remote.dart' show NewEvent;
import 'extension_host.dart';

/// The calls of the extension API about the person's tasks, reminders and calendar. They belong to no note, so the
/// editor (for the assistant and the extensions) and the MCP server answer them the same way: each says where the data is.
mixin LibraryApi on ExtensionApi {
  /// Null where tasks cannot be reached.
  TaskRepository? get libraryTasks;
  ReminderService? get libraryReminders;
  CalendarAccess? get libraryCalendar;

  /// The note a reminder can be about, when there is one.
  String? get libraryNoteId;

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';
  static String _stamp(DateTime t, bool allDay) => allDay ? _day(t) : '${_day(t)}T${_two(t.hour)}:${_two(t.minute)}';

  // ---- tasks

  TaskRepository _tasks() => libraryTasks ?? (throw ExtensionError('Tasks cannot be looked at here.'));

  Future<Task> _task(String id) async {
    final found = (await _tasks().listTasks()).where((t) => t.id == id).firstOrNull;
    return found ?? (throw ExtensionError('There is no task with the id "$id". tasks.list has the ids.'));
  }

  @override
  Future<List<Map<String, Object?>>> listTasks({bool? done}) async => [
        for (final t in (await _tasks().listTasks()).where((t) => done == null || t.done == done).take(100))
          {'id': t.id, 'title': t.title, 'due': t.dueDate == null ? null : _day(t.dueDate!), 'done': t.done},
      ];

  @override
  Future<void> completeTask(String id, {bool done = true}) async {
    await _task(id);
    await _tasks().setDone(id, done);
  }

  @override
  Future<void> updateTask(String id, {String? title, String? due, bool setDue = false}) async {
    final t = await _task(id);
    await _tasks().updateTask(id, title: title ?? t.title, dueDate: setDue ? (due == null ? null : DateTime.parse(due)) : t.dueDate);
  }

  @override
  Future<void> removeTask(String id) async {
    await _task(id);
    await _tasks().deleteTask(id);
  }

  // ---- reminders

  @override
  Future<String> addReminder(String text, String at, {String repeat = 'once', bool aboutNote = false}) async {
    final service = libraryReminders;
    if (service == null) throw ExtensionError('Reminders cannot be set here.');
    final time = DateTime.parse(at);
    final again = Repeat.byName(repeat == 'once' ? 'none' : repeat);
    if (again == Repeat.none && !time.isAfter(DateTime.now())) throw ExtensionError('$at is in the past.');
    if (aboutNote && libraryNoteId == null) throw ExtensionError('There is no note for the reminder to open.');
    return service.reminders.add(
      kind: aboutNote ? ReminderKind.note : ReminderKind.custom,
      refId: aboutNote ? libraryNoteId : null,
      title: text.trim(),
      at: time,
      repeat: again,
    );
  }

  @override
  Future<List<Map<String, Object?>>> listReminders() async {
    final service = libraryReminders;
    if (service == null) throw ExtensionError('Reminders cannot be looked at here.');
    return [
      for (final r in (await service.reminders.all()).where((r) => !r.auto && r.kind != ReminderKind.review).take(50))
        {'id': r.id, 'text': r.title, 'at': r.at.toIso8601String().substring(0, 16), 'repeat': r.repeat == Repeat.none ? 'once' : r.repeat.name},
    ];
  }

  @override
  Future<void> removeReminder(String id) async {
    final service = libraryReminders;
    if (service == null) throw ExtensionError('Reminders cannot be removed here.');
    if (!(await service.reminders.all()).any((r) => r.id == id && !r.auto)) throw ExtensionError('There is no reminder with the id "$id". reminders.list has the ids.');
    await service.reminders.remove(id);
  }

  // ---- the calendar

  @override
  Future<List<Map<String, Object?>>> listEvents(String from, String to) async {
    final access = libraryCalendar;
    if (access == null) throw ExtensionError('The calendar cannot be looked at here.');
    final last = DateTime.parse(to);
    final events = await access.events(DateTime.parse(from), DateTime(last.year, last.month, last.day, 23, 59, 59));
    return [
      for (final e in events.take(100))
        {'title': e.title, 'start': _stamp(e.start, e.allDay), 'end': e.end == null ? null : _stamp(e.end!, e.allDay), 'allDay': e.allDay, 'calendar': e.calendarName},
    ];
  }

  @override
  Future<void> addEvent(String title, String start, {String? end, bool allDay = false, String? calendar, String? description}) async {
    final access = libraryCalendar;
    if (access == null) throw ExtensionError('Events cannot be added here.');
    final targets = await access.writable();
    if (targets.isEmpty) throw ExtensionError('There is no calendar that events can be added to (connect a calendar in the settings).');
    final target = calendar == null || calendar.trim().isEmpty
        ? targets.first
        : (targets.where((c) => c.name.toLowerCase() == calendar.trim().toLowerCase()).firstOrNull ??
            (throw ExtensionError('There is no calendar "$calendar". The calendars are: ${targets.map((c) => c.name).join(', ')}.')));
    final first = DateTime.parse(start);
    final last = end == null ? null : DateTime.parse(end);
    if (last != null && last.isBefore(first)) throw ExtensionError('"end" is before "start".');
    await access.create(
      target,
      NewEvent(title: title.trim(), start: first, end: allDay ? last : (last ?? first.add(const Duration(hours: 1))), allDay: allDay, description: description ?? ''),
    );
  }
}
