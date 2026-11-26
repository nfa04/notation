import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/reminder_repository.dart';
import '../l10n/language.dart';
import '../data/task_repository.dart';
import 'notification_sink.dart';
import 'reminder.dart';

/// Tells the person about the reminders when their time comes: the ones they set for notes and things to do, and the due dates of
/// tasks. It keeps the reminders in step with the tasks, shows what is due while the app runs (a timer), and where the system can
/// do it also when the app is closed ([NotificationSink.supportsScheduling]) schedules the next ones ahead.
class ReminderService extends ChangeNotifier {
  static const tasksKey = 'reminders_tasks';
  static const timeKey = 'reminders_task_time';
  static const studyKey = 'reminders_study';

  /// How far ahead, and how many, notifications are handed to the system (iOS keeps 64 at most).
  static const _horizon = Duration(days: 30);
  static const _perReminder = 8;
  static const _total = 56;

  final ReminderRepository reminders;
  final TaskRepository? tasks;
  final NotificationSink sink;
  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;
  final DateTime Function() _now;

  /// Opens what a notification was about: a note, or the calendar for a task.
  void Function(ReminderKind kind, String? refId)? onOpen;

  /// When the study session whose to-do is the given task starts (null: the task is not a session's). Such a to-do is announced at
  /// the session's start rather than in the morning of its day.
  DateTime? Function(String taskId)? studyStart;

  /// The alarms of the events of the app's own calendars that go off between two moments (null: there are none to announce).
  Future<List<EventAlarm>> Function(DateTime from, DateTime to)? eventAlarms;

  ReminderService({
    required this.reminders,
    this.tasks,
    required this.sink,
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    DateTime Function()? clock,
  })  : _read = read,
        _write = write,
        _now = clock ?? DateTime.now;

  bool _tasksOn = true;
  bool _studyOn = true;
  int _taskMinutes = 9 * 60;
  bool _available = false;
  bool _allowed = false;
  Timer? _timer;
  StreamSubscription<void>? _remindersSub, _tasksSub;
  Future<void>? _running;
  bool _again = false, _disposed = false;

  /// Whether the due dates of tasks are announced.
  bool get tasksOn => _tasksOn;

  /// Whether study sessions are announced when they start.
  bool get studyOn => _studyOn;

  /// The time of day (minutes after midnight) a task is announced on its due date.
  int get taskMinutes => _taskMinutes;

  /// Whether the system can show notifications at all, and whether the person allowed them.
  bool get available => _available;
  bool get allowed => _allowed;

  Future<void> load() async {
    _tasksOn = await _read(tasksKey) != '0';
    _studyOn = await _read(studyKey) != '0';
    _taskMinutes = int.tryParse(await _read(timeKey) ?? '')?.clamp(0, 24 * 60 - 1) ?? 9 * 60;
    notifyListeners();
  }

  /// Gets the system ready and starts keeping time. Safe to call once.
  Future<void> start() async {
    try {
      _available = await sink.init(_tapped);
    } catch (_) {
      _available = false;
    }
    if (_available) {
      try {
        _allowed = await sink.isPermitted();
      } catch (_) {
        _allowed = false;
      }
    }
    _remindersSub = reminders.changes.listen((_) => unawaited(reconcile()));
    _tasksSub = tasks?.changes.listen((_) => unawaited(reconcile()));
    notifyListeners();
    await reconcile();
  }

  /// Makes sure the person was asked for the permission to notify (once it is given, or refused in the system's settings, asking
  /// again does nothing). Called when the person sets up a reminder: that is the moment they want to be told.
  Future<bool> ensurePermission() async {
    if (_available && !_allowed) await askPermission();
    return _allowed;
  }

  /// Asks again for the permission to notify (the person said no at first, or changed their mind in the system's settings).
  Future<void> askPermission() async {
    try {
      _allowed = await sink.requestPermission();
    } catch (_) {
      _allowed = false;
    }
    notifyListeners();
    await reconcile();
  }

  Future<void> setTasksOn(bool on) async {
    _tasksOn = on;
    await _write(tasksKey, on ? '1' : '0');
    notifyListeners();
    await reconcile();
  }

  Future<void> setStudyOn(bool on) async {
    _studyOn = on;
    await _write(studyKey, on ? '1' : '0');
    notifyListeners();
    await reconcile();
  }

  Future<void> setTaskMinutes(int minutes) async {
    _taskMinutes = minutes.clamp(0, 24 * 60 - 1);
    await _write(timeKey, '$_taskMinutes');
    notifyListeners();
    await reconcile();
  }

  void _tapped(String? payload) {
    if (payload == null || onOpen == null) return;
    final i = payload.indexOf(':');
    final kind = ReminderKind.values.where((k) => k.name == (i < 0 ? payload : payload.substring(0, i))).firstOrNull;
    if (kind == null) return;
    onOpen!(kind, i < 0 ? null : payload.substring(i + 1));
  }

  static String payloadOf(Reminder r) => r.refId == null ? r.kind.name : '${r.kind.name}:${r.refId}';

  /// An id for the system's notification: stable for a reminder, different for each of its next occurrences.
  static int notificationId(String reminderId, int index) {
    var h = 0x811c9dc5;
    for (final c in reminderId.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0x7fffff;
    }
    return (h << 8) | (index & 0xff);
  }

  /// Makes the reminders for the due dates of open tasks, and takes away those of tasks that are done, gone or moved.
  Future<void> _syncTasks() async {
    final repo = tasks;
    if (repo == null) return;
    final everything = await reminders.all();
    final existing = {for (final r in everything) if ((r.kind == ReminderKind.task || r.kind == ReminderKind.study) && r.auto) r.refId: r};
    final wanted = <String, ({Task task, ReminderKind kind, DateTime at})>{};
    final open = <String>{};
    for (final t in await repo.listTasks()) {
      if (t.done) continue;
      open.add(t.id);
      final session = studyStart?.call(t.id);
      if (session != null) {
        if (_studyOn) wanted[t.id] = (task: t, kind: ReminderKind.study, at: session);
      } else if (_tasksOn && t.dueDate != null) {
        final due = t.dueDate!;
        wanted[t.id] = (task: t, kind: ReminderKind.task, at: DateTime(due.year, due.month, due.day, _taskMinutes ~/ 60, _taskMinutes % 60));
      }
    }
    // a reminder the person set for a task goes with the task once it is done or deleted
    for (final r in everything) {
      if (r.kind == ReminderKind.task && !r.auto && r.refId != null && !open.contains(r.refId)) await reminders.remove(r.id);
    }
    for (final e in existing.entries) {
      if (wanted[e.key]?.kind != e.value.kind) await reminders.remove(e.value.id);
    }
    for (final w in wanted.values) {
      final t = w.task;
      final have = existing[t.id];
      if (have == null || have.kind != w.kind) {
        await reminders.add(kind: w.kind, refId: t.id, title: t.title, at: w.at, auto: true);
      } else if (have.at != w.at || have.title != t.title) {
        await reminders.update(have.id, title: t.title, at: w.at);
      }
    }
  }

  /// Announces what is due, hands the next ones to the system and sets the timer for the one after. Runs one at a time; a call that
  /// comes while it runs makes it run once more.
  Future<void> reconcile() {
    if (_disposed) return Future.value();
    if (_running != null) {
      _again = true;
      return _running!; // (the caller waits for the round that will see its change)
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      try {
        await _reconcileOnce();
      } catch (_) {
        // the app is closing and the database with it
        if (!_disposed) rethrow;
      }
    } while (_again && !_disposed);
  }

  /// Makes a reminder for each alarm of an event that is coming up (within the horizon), and takes away those of alarms that were
  /// taken out, or of events that were moved or deleted.
  Future<void> _syncEvents() async {
    final source = eventAlarms;
    if (source == null) return;
    final now = _now();
    // (a day back: an alarm that has just gone off is still wanted, until it was announced and its day is over)
    final wanted = {for (final a in await source(now.subtract(const Duration(days: 1)), now.add(_horizon))) a.key: a};
    final existing = {for (final r in await reminders.all()) if (r.kind == ReminderKind.event && r.auto) r.refId: r};
    for (final e in existing.entries) {
      if (!wanted.containsKey(e.key)) await reminders.remove(e.value.id);
    }
    for (final a in wanted.values) {
      final have = existing[a.key];
      if (have == null) {
        // (an alarm that went off long ago, while the app was closed, is not announced now that the event was made or the app opened)
        if (a.at.isBefore(now.subtract(const Duration(minutes: 5)))) continue;
        await reminders.add(kind: ReminderKind.event, refId: a.key, title: a.title, at: a.at, auto: true);
      } else if (have.at != a.at || have.title != a.title) {
        await reminders.update(have.id, title: a.title, at: a.at);
      }
    }
  }

  Future<void> _reconcileOnce() async {
    await _syncTasks();
    await _syncEvents();
    final now = _now();
    var all = await reminders.all();
    for (final r in all) {
      final pending = r.pending;
      if (pending == null || pending.isAfter(now)) continue;
      // many missed occurrences are one announcement, for the latest; where the system does the announcing it did so already
      final latest = occurrenceAtOrBefore(r.at, r.repeat, now) ?? pending;
      if (_available && _allowed && !sink.supportsScheduling) await _show(r);
      await reminders.markFired(r.id, latest);
    }
    all = await reminders.all();
    if (_available && _allowed && sink.supportsScheduling) await _scheduleAhead(all, now);
    _arm(all, now);
    if (!_disposed) notifyListeners();
  }

  Future<void> _show(Reminder r) async {
    try {
      await sink.show(id: notificationId(r.id, 0), title: r.title, body: _body(r), payload: payloadOf(r));
    } catch (_) {
      // a notification that cannot be shown is lost; the others still are
    }
  }

  static String _body(Reminder r) => switch (r.kind) {
        ReminderKind.note => tr('Time to look at this note'),
        ReminderKind.task => tr('A task is due'),
        ReminderKind.review => tr('Time for your weekly review'),
        ReminderKind.study => tr('Your study session starts now'),
        ReminderKind.event => tr('An event is coming up'),
        ReminderKind.custom => tr('Reminder'),
      };

  Future<void> _scheduleAhead(List<Reminder> all, DateTime now) async {
    try {
      await sink.cancelScheduled();
      final until = now.add(_horizon);
      var left = _total;
      final coming = <(DateTime, Reminder, int)>[];
      for (final r in all) {
        final times = r.occurrencesFrom(now, count: _perReminder, until: until);
        for (var i = 0; i < times.length; i++) {
          coming.add((times[i], r, i));
        }
      }
      coming.sort((a, b) => a.$1.compareTo(b.$1));
      for (final (at, r, i) in coming) {
        if (left-- <= 0) break;
        await sink.schedule(id: notificationId(r.id, i), at: at, title: r.title, body: _body(r), payload: payloadOf(r));
      }
    } catch (_) {
      // the system refused (no permission to schedule); the timer still announces while the app runs
    }
  }

  void _arm(List<Reminder> all, DateTime now) {
    _timer?.cancel();
    _timer = null;
    DateTime? soonest;
    for (final r in all) {
      final p = r.pending;
      if (p != null && (soonest == null || p.isBefore(soonest))) soonest = p;
    }
    if (soonest == null || _disposed) return;
    var wait = soonest.difference(now);
    if (wait < const Duration(seconds: 1)) wait = const Duration(seconds: 1);
    // not longer than an hour at a time: the clock may be changed, and a sleeping computer loses its timers
    if (wait > const Duration(hours: 1)) wait = const Duration(hours: 1);
    _timer = Timer(wait, () => unawaited(reconcile()));
  }

  /// The reminders still to come (and the ones that are over are not listed), the next first.
  Future<List<Reminder>> upcoming() async => [for (final r in await reminders.all()) if (r.pending != null) r];

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _remindersSub?.cancel();
    _tasksSub?.cancel();
    super.dispose();
  }
}
