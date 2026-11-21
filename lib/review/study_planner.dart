import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../data/card_repository.dart';
import '../data/settings_repository.dart';
import '../data/task_repository.dart';
import '../l10n/language.dart';
import '../sync/caldav_remote.dart';
import 'study_calendar.dart';
import 'study_material.dart';
import 'study_plan.dart';
import 'study_schedule.dart';

String dayKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// A session that was put on the calendar: what was planned, and the to-do and the event it became.
class BookedSession {
  final PlannedSession session;
  final String title;
  final String? taskId;

  /// The event and the calendar it is in (null: none, a plan of to-dos only, or writing it failed).
  final String? eventId, eventTarget;

  /// Its work counts as done (its to-do was ticked off).
  final bool credited;

  /// It went by without being done and the plan was made again since (it is not reported again).
  final bool skipped;

  const BookedSession(this.session, this.title, {this.taskId, this.eventId, this.eventTarget, this.credited = false, this.skipped = false});

  String get key => session.key;

  BookedSession copyWith({bool? credited, bool? skipped}) =>
      BookedSession(session, title, taskId: taskId, eventId: eventId, eventTarget: eventTarget, credited: credited ?? this.credited, skipped: skipped ?? this.skipped);

  Map<String, Object?> toJson() => {
        'start': session.start.toIso8601String(),
        'min': session.minutes,
        'items': [for (final i in session.items) i.toJson()],
        'title': title,
        if (taskId != null) 'task': taskId,
        if (eventId != null) 'event': eventId,
        if (eventTarget != null) 'cal': eventTarget,
        if (credited) 'done': true,
        if (skipped) 'skip': true,
      };

  static BookedSession? fromJson(Object? j) {
    if (j is! Map || j['start'] is! String) return null;
    final start = DateTime.tryParse(j['start'] as String);
    if (start == null) return null;
    return BookedSession(
      PlannedSession(start, (j['min'] as num?)?.toInt() ?? 30, [for (final i in (j['items'] as List?) ?? const []) ?SessionItem.fromJson(i)]),
      (j['title'] as String?) ?? '',
      taskId: j['task'] as String?,
      eventId: j['event'] as String?,
      eventTarget: j['cal'] as String?,
      credited: j['done'] == true,
      skipped: j['skip'] == true,
    );
  }
}

/// Where the sessions of a plan go: a calendar ([key]), a calendar to be made at [make], or nowhere but the to-dos (both null).
class CalendarTarget {
  final String? key;
  final CalendarPlace? make;
  const CalendarTarget.calendar(String this.key) : make = null;
  const CalendarTarget.makeAt(CalendarPlace this.make) : key = null;
  const CalendarTarget.none()
      : key = null,
        make = null;

  bool get isNone => key == null && make == null;

  @override
  bool operator ==(Object other) => other is CalendarTarget && other.key == key && other.make == make;

  @override
  int get hashCode => Object.hash(key, make);
}

/// A plan for an exam: the material (in units), the flashcards, the hours to study in, where the sessions go, how far the work is, and
/// the sessions that are booked.
class StudyPlanEntry {
  final String id;
  final String name;

  /// The day of the exam, and its time (minutes after midnight; null: not said).
  final DateTime exam;
  final int? examTime;
  final List<StudyUnit> units;

  /// The sources (notes, `anki:` decks) whose flashcards are part of the plan; null: all of them; empty: none.
  final Set<String>? cardSources;

  /// The hours of a day to study in (minutes after midnight), the weekdays without study (1 = Monday), at most how many minutes a
  /// day, and how long a session is.
  final int windowStart, windowEnd;
  final Set<int> daysOff;
  final int maxPerDay, sessionLength;

  /// Where the sessions go.
  final CalendarTarget target;

  /// How much of each unit is done.
  final Map<String, UnitProgress> progress;
  final List<BookedSession> sessions;

  /// Times the person did not want a session in.
  final List<Busy> blocked;

  /// The to-dos a plan made before sessions had times (day -> task), taken away once the plan is made again.
  final Map<String, String> legacyTasks;

  const StudyPlanEntry({
    required this.id,
    required this.name,
    required this.exam,
    this.examTime,
    this.units = const [],
    this.cardSources,
    this.windowStart = 16 * 60,
    this.windowEnd = 20 * 60,
    this.daysOff = const {},
    this.maxPerDay = 120,
    this.sessionLength = 45,
    this.target = const CalendarTarget.none(),
    this.progress = const {},
    this.sessions = const [],
    this.blocked = const [],
    this.legacyTasks = const {},
  });

  StudyTime get time => StudyTime.daily(StudyWindow(windowStart, windowEnd), daysOff: daysOff, maxPerDay: maxPerDay, sessionLength: sessionLength);

  StudyUnit? unit(String id) => units.where((u) => u.id == id).firstOrNull;

  /// How much of the learning is done (0..1), weighed by how long each unit takes.
  double get learned {
    final counted = units.where((u) => u.included).toList();
    final all = counted.fold<int>(0, (n, u) => n + u.learnMinutes);
    if (all == 0) return 0;
    return counted.fold<double>(0, (n, u) => n + u.learnMinutes * (progress[u.id]?.learned ?? 0)) / all;
  }

  StudyPlanEntry copyWith({
    String? name,
    DateTime? exam,
    int? Function()? examTime,
    List<StudyUnit>? units,
    Set<String>? Function()? cardSources,
    int? windowStart,
    int? windowEnd,
    Set<int>? daysOff,
    int? maxPerDay,
    int? sessionLength,
    CalendarTarget? target,
    Map<String, UnitProgress>? progress,
    List<BookedSession>? sessions,
    List<Busy>? blocked,
    Map<String, String>? legacyTasks,
  }) =>
      StudyPlanEntry(
        id: id,
        name: name ?? this.name,
        exam: exam ?? this.exam,
        examTime: examTime == null ? this.examTime : examTime(),
        units: units ?? this.units,
        cardSources: cardSources == null ? this.cardSources : cardSources(),
        windowStart: windowStart ?? this.windowStart,
        windowEnd: windowEnd ?? this.windowEnd,
        daysOff: daysOff ?? this.daysOff,
        maxPerDay: maxPerDay ?? this.maxPerDay,
        sessionLength: sessionLength ?? this.sessionLength,
        target: target ?? this.target,
        progress: progress ?? this.progress,
        sessions: sessions ?? this.sessions,
        blocked: blocked ?? this.blocked,
        legacyTasks: legacyTasks ?? this.legacyTasks,
      );

  Map<String, Object?> toJson() => {
        'v': 2,
        'id': id,
        'name': name,
        'exam': dayKey(exam),
        if (examTime != null) 'examAt': examTime,
        'units': [for (final u in units) u.toJson()],
        if (cardSources != null) 'cards': cardSources!.toList(),
        'from': windowStart,
        'until': windowEnd,
        'off': daysOff.toList(),
        'max': maxPerDay,
        'len': sessionLength,
        if (target.key != null) 'cal': target.key,
        'progress': {for (final e in progress.entries) e.key: [e.value.learned, e.value.reviewed]},
        'sessions': [for (final s in sessions) s.toJson()],
        'blocked': [for (final b in blocked) [b.start.toIso8601String(), b.end.toIso8601String()]],
        if (legacyTasks.isNotEmpty) 'tasks': legacyTasks,
      };

  /// A plan as it was kept; one kept before sessions had times (only flashcards, a to-do a day) is read with its to-dos kept aside.
  static StudyPlanEntry? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['exam'] is! String) return null;
    final exam = DateTime.tryParse(j['exam'] as String);
    if (exam == null) return null;
    final legacy = j['v'] == null;
    final source = j['source'] as String?;
    return StudyPlanEntry(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? '',
      exam: _day(exam),
      examTime: (j['examAt'] as num?)?.toInt(),
      units: [for (final u in (j['units'] as List?) ?? const []) ?StudyUnit.fromJson(u)],
      cardSources: legacy ? (source == null ? null : {source}) : (j['cards'] as List?)?.whereType<String>().toSet(),
      windowStart: (j['from'] as num?)?.toInt() ?? 16 * 60,
      windowEnd: (j['until'] as num?)?.toInt() ?? 20 * 60,
      daysOff: {for (final d in (j['off'] as List?) ?? const []) if (d is int && d >= 1 && d <= 7) d},
      maxPerDay: ((legacy ? j['minutes'] : j['max']) as num?)?.toInt() ?? (legacy ? 20 : 120),
      sessionLength: (j['len'] as num?)?.toInt() ?? 45,
      target: j['cal'] is String ? CalendarTarget.calendar(j['cal'] as String) : const CalendarTarget.none(),
      progress: {
        for (final e in ((j['progress'] as Map?) ?? const {}).entries)
          if (e.value is List && (e.value as List).length == 2) '${e.key}': (learned: ((e.value as List)[0] as num).toDouble(), reviewed: ((e.value as List)[1] as num).toDouble()),
      },
      sessions: [for (final s in (j['sessions'] as List?) ?? const []) ?BookedSession.fromJson(s)],
      blocked: [
        for (final b in (j['blocked'] as List?) ?? const [])
          if (b is List && b.length == 2 && DateTime.tryParse('${b[0]}') != null && DateTime.tryParse('${b[1]}') != null)
            (start: DateTime.parse('${b[0]}'), end: DateTime.parse('${b[1]}')),
      ],
      legacyTasks: {for (final e in ((j['tasks'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
    );
  }
}

/// How a proposed session compares with what is booked.
enum SessionChange { added, changed, same }

/// A session of a proposal, with its title and how it differs from the booked one at the same time.
class ProposedSession {
  final PlannedSession session;
  final String title;
  final SessionChange change;
  const ProposedSession(this.session, this.title, this.change);
}

/// A plan as it would be: the sessions, which booked sessions it takes away, the events around them (to show), and what does not fit.
/// Nothing is written until it is approved ([StudyPlanner.approve]).
class StudyProposal {
  final StudyPlanEntry entry;
  final StudySchedule schedule;
  final List<ProposedSession> sessions;

  /// Booked sessions that are not in the plan any more.
  final List<BookedSession> removed;

  /// The events of the calendars in the time of the plan (to show the sessions among them).
  final List<DayEvent> events;

  /// The calendars could not be read: free times were found without them.
  final bool calendarUnread;

  const StudyProposal(this.entry, this.schedule, this.sessions, {this.removed = const [], this.events = const [], this.calendarUnread = false});

  bool get hasChanges => removed.isNotEmpty || sessions.any((s) => s.change != SessionChange.same);
}

/// Why a plan wants to be looked at again.
class PlanAttention {
  /// Sessions that went by without their to-do being ticked off.
  final int missed;

  /// Booked sessions that now clash with an event.
  final int clashes;

  /// Booked sessions whose to-do was deleted.
  final int dropped;

  /// Nothing is booked yet (a plan from before sessions had times, or one whose writing failed).
  final bool unbooked;

  const PlanAttention({this.missed = 0, this.clashes = 0, this.dropped = 0, this.unbooked = false});

  bool get any => missed > 0 || clashes > 0 || dropped > 0 || unbooked;
}

/// The plans for exams. A plan is made from the material and the hours given, shown as a proposal and only put on the calendar (as
/// events, and as to-dos) once the person approves it. Ticking off a session's to-do counts its work as done. Sessions that were missed,
/// that clash with a new event or whose to-do was deleted are noticed ([attentionOf]); the plan is then proposed again, and again only
/// changed once approved.
class StudyPlanner extends ChangeNotifier {
  static const _key = 'study_plans';

  final SettingsRepository _settings;
  final CardRepository _cards;
  final TaskRepository _tasks;
  final StudyCalendarAccess? calendar;

  /// What can be read about a note to cut it into units (null: it is gone).
  final Future<NoteShape?> Function(String noteId)? readNote;
  final DateTime Function() _now;
  List<StudyPlanEntry> _plans = [];
  final Map<String, PlanAttention> _attention = {};
  StreamSubscription<void>? _sub;
  Timer? _soon, _daily;
  Future<void> _work = Future.value();

  /// Why the last approval could not write everything (null: it did).
  String? problem;

  StudyPlanner(this._settings, this._cards, this._tasks, {this.calendar, this.readNote, DateTime Function()? now}) : _now = now ?? DateTime.now;

  List<StudyPlanEntry> get plans => List.unmodifiable(_plans);

  PlanAttention attentionOf(String planId) => _attention[planId] ?? const PlanAttention();

  /// Whether [taskId] is the to-do of a session (such a to-do is not put on the calendar a second time by the task mirror).
  bool ownsTask(String taskId) => _plans.any((p) => p.sessions.any((s) => s.taskId == taskId) || p.legacyTasks.containsValue(taskId));

  Future<void> load() async {
    try {
      _plans = [for (final j in jsonDecode(await _settings.get(_key) ?? '[]') as List) ?StudyPlanEntry.fromJson(j)];
    } catch (_) {
      _plans = [];
    }
    notifyListeners();
  }

  /// Starts keeping the plans up to date: when a to-do changed (a moment after), and once every few hours.
  void start({Duration every = const Duration(hours: 6)}) {
    _sub ??= _tasks.changes.listen((_) {
      _soon?.cancel();
      _soon = Timer(const Duration(seconds: 3), () => refresh());
    });
    _daily?.cancel();
    _daily = Timer.periodic(every, (_) => refresh());
    unawaited(refresh());
  }

  Future<void> _save() => _settings.set(_key, jsonEncode([for (final p in _plans) p.toJson()]));

  /// A new plan that is not kept yet (it is kept once it is approved).
  StudyPlanEntry draft({required String name, required DateTime exam}) =>
      StudyPlanEntry(id: '${_now().microsecondsSinceEpoch}', name: name.trim(), exam: _day(exam));

  /// The units of a note (none when it cannot be read).
  Future<List<StudyUnit>> unitsOf(String noteId) async {
    final shape = await readNote?.call(noteId);
    return shape == null ? const [] : unitsOfNote(shape);
  }

  /// How many cards each source (a note, a deck) has.
  Future<Map<String, int>> sourceCounts() => _cards.sourceCounts();

  Future<CardStats?> _cardStats(StudyPlanEntry e) async {
    final sources = e.cardSources;
    if (sources != null && sources.isEmpty) return null;
    if (sources == null) return _cards.stats(now: _now());
    var unseen = 0, seen = 0, due = 0, weak = 0;
    for (final s in sources) {
      final st = await _cards.stats(source: s, now: _now());
      unseen += st.unseen;
      seen += st.seen;
      due += st.due;
      weak += st.weak;
    }
    return CardStats(unseen: unseen, seen: seen, due: due, weak: weak);
  }

  /// Minutes a day for the flashcards (from the card plan), for the days before the exam.
  Future<Map<DateTime, int>> _cardMinutes(StudyPlanEntry e) async {
    final stats = await _cardStats(e);
    if (stats == null || stats.total == 0) return const {};
    final budget = (e.maxPerDay ~/ 4).clamp(10, 30);
    final plan = planStudy(today: _now(), exam: e.exam, stats: stats, minutesPerDay: budget, daysOff: e.daysOff);
    return {for (final s in plan.sessions) if (!s.examDay) _day(s.day): s.minutes};
  }

  bool _done(BookedSession s, Map<String, Task> tasks) => s.credited || (s.taskId != null && tasks[s.taskId]?.done == true);

  /// The booked sessions of [e] that stay whatever the new plan is: those that began already, and those that are done.
  List<BookedSession> _kept(StudyPlanEntry e, Map<String, Task> tasks) => [for (final s in e.sessions) if (!s.session.start.isAfter(_now()) || _done(s, tasks)) s];

  /// The sessions [e] would have now (from what is done, the calendars and the hours given), compared with what is booked.
  Future<StudyProposal> propose(StudyPlanEntry draft) async {
    var e = draft;
    final now = _now();
    final tasks = {for (final t in await _tasks.listTasks()) t.id: t};
    e = _credit(e, tasks);
    final kept = _kept(e, tasks);
    final until = DateTime(e.exam.year, e.exam.month, e.exam.day + 1);
    var events = <DayEvent>[];
    var unread = false;
    if (calendar != null) {
      try {
        events = await calendar!.events(_day(now), until);
      } catch (err) {
        debugPrint('reading the calendars for a study plan failed: $err');
        unread = true;
      }
    }
    // (the plan's own events, in the calendar they were written to; an event elsewhere at the same time is a busy time)
    final own = [for (final s in e.sessions) if (s.eventTarget != null) (s.eventTarget, s.session.start, s.session.end)];
    bool isOwn(DayEvent ev) => own.any((o) => o.$1 == ev.calendarKey && o.$2 == ev.start && (ev.end == null || o.$3 == ev.end));
    events = [for (final ev in events) if (!ev.allDay && !isOwn(ev)) ev]..sort((a, b) => a.start.compareTo(b.start));
    final busy = <Busy>[
      for (final ev in events) (start: ev.start, end: ev.end ?? ev.start.add(const Duration(hours: 1))),
      for (final p in _plans)
        if (p.id != e.id)
          for (final s in p.sessions) (start: s.session.start, end: s.session.end),
      for (final s in kept) (start: s.session.start, end: s.session.end),
      ...e.blocked,
    ];
    final schedule = scheduleStudy(
      now: now,
      exam: e.exam,
      examTime: e.examTime,
      units: e.units,
      progress: e.progress,
      time: e.time,
      busy: busy,
      cardMinutes: await _cardMinutes(e),
    );
    final booked = {for (final s in e.sessions) if (!kept.contains(s)) s.key: s};
    final proposed = <ProposedSession>[];
    for (final s in schedule.sessions) {
      final title = sessionTitleOf(e.name, s, e.unit);
      final old = booked.remove(s.key);
      final same = old != null && old.session.minutes == s.minutes && old.title == title && listEquals(old.session.items, s.items) && (old.taskId == null || tasks.containsKey(old.taskId));
      proposed.add(ProposedSession(s, title, old == null ? SessionChange.added : (same ? SessionChange.same : SessionChange.changed)));
    }
    return StudyProposal(e, schedule, proposed, removed: booked.values.toList(), events: events, calendarUnread: unread);
  }

  /// [e] with the work of the sessions whose to-do was ticked off counted in (once: such a session is marked as counted).
  StudyPlanEntry _credit(StudyPlanEntry e, Map<String, Task> tasks) {
    if (!e.sessions.any((s) => !s.credited && _done(s, tasks))) return e;
    final out = {...e.progress};
    for (final s in e.sessions) {
      if (s.credited || !_done(s, tasks)) continue;
      for (final i in s.session.items) {
        if (i.unitId == null) continue;
        final p = out[i.unitId!] ?? (learned: 0.0, reviewed: 0.0);
        final share = i.to - i.from;
        out[i.unitId!] = i.kind == WorkKind.learn
            ? (learned: math.min(1.0, p.learned + share), reviewed: p.reviewed)
            : i.kind == WorkKind.review
                ? (learned: p.learned, reviewed: math.min(1.0, p.reviewed + share))
                : p;
      }
    }
    return e.copyWith(progress: out, sessions: [for (final s in e.sessions) _done(s, tasks) ? s.copyWith(credited: true) : s]);
  }

  String _taskTitle(ProposedSession s) => '${_clock(s.session.start)} ${s.title}';

  NewEvent _event(StudyPlanEntry e, ProposedSession s) => NewEvent(
        title: s.title,
        start: s.session.start,
        end: s.session.end,
        description: [
          for (final i in s.session.items) '- ${itemText(i, i.unitId == null ? null : e.unit(i.unitId!))}',
          '',
          tr('Planned by Notation for {plan}', {'plan': e.name}),
        ].join('\n'),
      );

  /// Puts [p] on the calendar and in the to-dos and keeps the plan: sessions taken away lose their event and their to-do (a done one
  /// stays), changed ones are written anew, new ones are added. A calendar that is still to be made is made first. Writing goes on past an
  /// event that fails (its to-do is still made; [problem] says what went wrong, and the next approval tries the event again).
  Future<StudyPlanEntry> approve(StudyProposal p) async {
    problem = null;
    final cal = calendar;
    final tasks = {for (final t in await _tasks.listTasks()) t.id: t};
    var e = _credit(p.entry, tasks);
    final errors = <String>[];

    var target = e.target;
    if (target.make != null && cal != null) {
      try {
        final existing = (await cal.writable()).where((c) => c.name == tr('Study')).firstOrNull;
        target = CalendarTarget.calendar((existing ?? await cal.makeCalendar(target.make!, tr('Study'))).key);
      } catch (err) {
        errors.add(tr('The calendar could not be made: {error}', {'error': '$err'.replaceFirst('Bad state: ', '')}));
        target = const CalendarTarget.none();
      }
    } else if (target.make != null) {
      target = const CalendarTarget.none();
    }
    e = e.copyWith(target: target);

    Future<void> unbook(BookedSession s) async {
      if (s.eventId != null && s.eventTarget != null && cal != null) {
        try {
          await cal.delete(s.eventTarget!, s.eventId!);
        } catch (err) {
          errors.add('$err');
        }
      }
      final t = s.taskId == null ? null : tasks[s.taskId];
      if (t != null && !t.done) await _tasks.deleteTask(t.id);
    }

    Future<({String? id, String? target})> write(ProposedSession s) async {
      final key = target.key;
      if (key == null || cal == null) return (id: null, target: null);
      try {
        return (id: await cal.create(key, _event(e, s)), target: key);
      } catch (err) {
        errors.add('$err'.replaceFirst('Bad state: ', ''));
        return (id: null, target: null);
      }
    }

    // the sessions that stay: those that began and those that are done; one that went by undone is not reported again
    final kept = [for (final s in _kept(e, tasks)) s.credited ? s : s.copyWith(skipped: true)];
    final booked = {for (final s in e.sessions) if (!kept.any((k) => k.key == s.key)) s.key: s};
    for (final s in p.removed) {
      await unbook(s);
      booked.remove(s.key);
    }
    final next = <BookedSession>[...kept];
    for (final s in p.sessions) {
      final old = booked.remove(s.session.key);
      if (old != null && s.change == SessionChange.same && (old.eventTarget == target.key || target.key == null && old.eventTarget == null) && (old.eventId != null || target.key == null)) {
        next.add(old);
        continue;
      }
      if (old != null) await unbook(old);
      final taskId = await _tasks.createTask(_taskTitle(s), dueDate: _day(s.session.start), auto: true);
      final ev = await write(s);
      next.add(BookedSession(s.session, s.title, taskId: taskId, eventId: ev.id, eventTarget: ev.target));
    }
    for (final s in booked.values) {
      await unbook(s); // (booked, but neither in the plan nor said to be taken away: an older proposal)
    }
    // the to-dos of a plan from before sessions had times
    final today = dayKey(_now());
    for (final entry in e.legacyTasks.entries) {
      final t = tasks[entry.value];
      if (entry.key.compareTo(today) >= 0 && t != null && !t.done) await _tasks.deleteTask(t.id);
    }
    next.sort((a, b) => a.session.start.compareTo(b.session.start));
    e = e.copyWith(sessions: next, legacyTasks: const {});
    final i = _plans.indexWhere((x) => x.id == e.id);
    _plans = i < 0 ? [..._plans, e] : [for (final x in _plans) x.id == e.id ? e : x];
    _attention.remove(e.id);
    if (errors.isNotEmpty) problem = errors.toSet().join('\n');
    await _save();
    notifyListeners();
    return e;
  }

  /// Takes the plan away, with its sessions that are still to come (their events and their to-dos; what was done stays).
  Future<void> remove(String id) async {
    final entry = _plans.where((p) => p.id == id).firstOrNull;
    if (entry == null) return;
    final tasks = {for (final t in await _tasks.listTasks()) t.id: t};
    final now = _now();
    for (final s in entry.sessions) {
      if (!s.session.start.isAfter(now)) continue;
      final t = s.taskId == null ? null : tasks[s.taskId];
      if (t?.done == true) continue;
      if (s.eventId != null && s.eventTarget != null) {
        try {
          await calendar?.delete(s.eventTarget!, s.eventId!);
        } catch (err) {
          debugPrint('taking a study session off the calendar failed: $err');
        }
      }
      if (t != null) await _tasks.deleteTask(t.id);
    }
    final today = dayKey(now);
    for (final e in entry.legacyTasks.entries) {
      final t = tasks[e.value];
      if (e.key.compareTo(today) >= 0 && t != null && !t.done) await _tasks.deleteTask(t.id);
    }
    _plans = [for (final p in _plans) if (p.id != id) p];
    _attention.remove(id);
    await _save();
    notifyListeners();
  }

  /// Counts the work of sessions whose to-do was ticked off, drops plans whose exam is over, and notices what wants the plan made again.
  /// Nothing on the calendar is changed here.
  Future<void> refresh() {
    _work = _work.then((_) => _refresh()).catchError((Object err) => debugPrint('refreshing the study plans failed: $err'));
    return _work;
  }

  Future<void> _refresh() async {
    final now = _now();
    final today = _day(now);
    final tasks = {for (final t in await _tasks.listTasks()) t.id: t};
    var changed = false;
    final next = <StudyPlanEntry>[];
    for (final e in _plans) {
      if (e.exam.isBefore(today)) {
        changed = true; // the exam is over
        _attention.remove(e.id);
        continue;
      }
      final entry = _credit(e, tasks);
      if (!identical(entry, e)) changed = true;
      next.add(entry);
      final upcoming = [for (final s in entry.sessions) if (s.session.start.isAfter(now) && !s.credited) s];
      var clashes = 0;
      if (calendar != null && upcoming.isNotEmpty) {
        try {
          final events = await calendar!.events(today, DateTime(entry.exam.year, entry.exam.month, entry.exam.day + 1));
          for (final s in upcoming) {
            if (events.any((ev) =>
                !ev.allDay &&
                !(ev.calendarKey == s.eventTarget && ev.start == s.session.start) &&
                ev.start.isBefore(s.session.end) &&
                (ev.end ?? ev.start.add(const Duration(hours: 1))).isAfter(s.session.start))) {
              clashes++;
            }
          }
        } catch (_) {
          // the calendars cannot be read now: nothing is said about clashes
        }
      }
      _attention[entry.id] = PlanAttention(
        missed: entry.sessions.where((s) => !s.credited && !s.skipped && !s.session.end.isAfter(now) && s.taskId != null && tasks[s.taskId] != null).length,
        dropped: upcoming.where((s) => s.taskId != null && !tasks.containsKey(s.taskId)).length,
        clashes: clashes,
        unbooked: entry.sessions.isEmpty,
      );
    }
    _plans = next;
    if (changed) await _save();
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _soon?.cancel();
    _daily?.cancel();
    super.dispose();
  }
}
