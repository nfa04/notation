import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../ai/text_provider.dart' show AiCancel;
import '../data/card_repository.dart';
import '../data/note_repository.dart';
import '../data/settings_repository.dart';
import '../data/task_repository.dart';
import '../graph/study.dart';
import '../l10n/language.dart';
import '../sync/caldav_remote.dart';
import 'study_calendar.dart';
import 'study_generate.dart';
import 'study_material.dart';
import 'study_plan.dart';
import 'study_practice.dart';
import 'study_schedule.dart';
import 'study_topics.dart';

String dayKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Whether [ev] is the event [id] that was written for a session: a phone event by its id, a server event by its address (which ends in
/// the event's UID).
bool isEventOf(DayEvent ev, String id) => ev.uid.isNotEmpty && (ev.uid == id || id.endsWith('/${ev.uid}.ics'));

/// How a session felt, as said at its end.
enum SessionFeeling { easy, fine, hard }

/// What the person said at the end of a session: how long they studied, which of its items they did, and how it went.
class SessionReport {
  /// Minutes studied (the time of the session's clock, pauses left out).
  final int spent;

  /// The items of the session (by their place in it) that were done.
  final Set<int> done;
  final SessionFeeling feeling;

  const SessionReport({required this.spent, required this.done, this.feeling = SessionFeeling.fine});

  Map<String, Object?> toJson() => {'min': spent, 'done': done.toList()..sort(), 'feel': feeling.name};

  static SessionReport? fromJson(Object? j) {
    if (j is! Map) return null;
    return SessionReport(
      spent: (j['min'] as num?)?.toInt() ?? 0,
      done: {for (final i in (j['done'] as List?) ?? const []) if (i is int) i},
      feeling: SessionFeeling.values.where((f) => f.name == j['feel']).firstOrNull ?? SessionFeeling.fine,
    );
  }
}

/// The session that is being studied now: since when, and how long it was paused.
class RunningSession {
  final String planId, key;
  final DateTime started;

  /// Paused since then (null: it runs), and the seconds of the pauses before.
  final DateTime? pausedAt;
  final int pausedSeconds;

  /// The items (by their place in the session) ticked off so far.
  final Set<int> checked;

  const RunningSession(this.planId, this.key, this.started, {this.pausedAt, this.pausedSeconds = 0, this.checked = const {}});

  RunningSession _with({DateTime? Function()? pausedAt, int? pausedSeconds, Set<int>? checked}) => RunningSession(planId, key, started,
      pausedAt: pausedAt == null ? this.pausedAt : pausedAt(), pausedSeconds: pausedSeconds ?? this.pausedSeconds, checked: checked ?? this.checked);

  bool get paused => pausedAt != null;

  Duration elapsed(DateTime now) {
    final d = (pausedAt ?? now).difference(started) - Duration(seconds: pausedSeconds);
    return d.isNegative ? Duration.zero : d;
  }

  Map<String, Object?> toJson() => {
        'plan': planId,
        'key': key,
        'start': started.toIso8601String(),
        if (pausedAt != null) 'paused': pausedAt!.toIso8601String(),
        'pauses': pausedSeconds,
        if (checked.isNotEmpty) 'checked': checked.toList()..sort(),
      };

  static RunningSession? fromJson(Object? j) {
    if (j is! Map || j['plan'] is! String || j['key'] is! String) return null;
    final start = DateTime.tryParse('${j['start']}');
    if (start == null) return null;
    return RunningSession(j['plan'] as String, j['key'] as String, start,
        pausedAt: j['paused'] == null ? null : DateTime.tryParse('${j['paused']}'),
        pausedSeconds: (j['pauses'] as num?)?.toInt() ?? 0,
        checked: {for (final i in (j['checked'] as List?) ?? const []) if (i is int) i});
  }
}

/// A session that was put on the calendar: what was planned, and the to-do and the event it became.
class BookedSession {
  final PlannedSession session;
  final String title;
  final String? taskId;

  /// The event and the calendar it is in (null: none, a plan of to-dos only, or writing it failed).
  final String? eventId, eventTarget;

  /// Its work counts as done (its to-do was ticked off).
  final bool credited;

  /// It went by without being done (or with work left), and the plan was made again since (it is not reported again).
  final bool skipped;

  /// What was said at its end (null: it was not studied with the session's screen).
  final SessionReport? report;

  /// Its event was deleted in the calendar app: the person does not want it then (its time is kept free when the plan is made again).
  final bool gone;

  /// Its event was moved in the calendar app, and it went with it: it stays where the person put it, with its work, when the plan is made
  /// again.
  final bool moved;

  const BookedSession(this.session, this.title,
      {this.taskId, this.eventId, this.eventTarget, this.credited = false, this.skipped = false, this.report, this.gone = false, this.moved = false});

  String get key => session.key;

  /// It was studied, and some of its items were not done.
  bool get unfinished => report != null && session.items.indexed.any((i) => !report!.done.contains(i.$1));

  BookedSession copyWith(
          {PlannedSession? session, bool? credited, bool? skipped, SessionReport? report, bool? gone, bool? moved, String? eventId, String? eventTarget}) =>
      BookedSession(session ?? this.session, title,
      taskId: taskId,
      eventId: eventId ?? this.eventId,
      eventTarget: eventTarget ?? this.eventTarget,
      credited: credited ?? this.credited,
      skipped: skipped ?? this.skipped,
      report: report ?? this.report,
      gone: gone ?? this.gone,
      moved: moved ?? this.moved);

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
        if (report != null) 'report': report!.toJson(),
        if (gone) 'gone': true,
        if (moved) 'moved': true,
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
      report: SessionReport.fromJson(j['report']),
      gone: j['gone'] == true,
      moved: j['moved'] == true,
    );
  }
}

/// An event that is to be deleted: its id, the calendar it is in, and the device that calendar is on (a phone calendar; null: another).
typedef StrayEvent = ({String id, String target, String? device});

/// The stray events kept as JSON (what cannot be read is left out).
List<StrayEvent> strayEventsOf(Object? j) => [
      for (final x in j is List ? j : const [])
        if (x is List && x.length >= 2 && x[0] is String && x[1] is String)
          (id: x[0] as String, target: x[1] as String, device: x.length > 2 && x[2] is String ? x[2] as String : null),
    ];

List<List<String>> _straysJson(List<StrayEvent> strays) => [for (final x in strays) [x.id, x.target, ?x.device]];

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

  /// How long the person takes compared with the estimates, as it was when the sessions were planned (1: as estimated).
  final double speed;

  /// The device whose phone calendar the sessions are in (only one device can read or write a phone's calendar); null: the target is
  /// not a phone calendar.
  final String? calendarDevice;

  /// The approval the sessions come from, and the one it was made after (to tell, when the plan comes from another device, whether that
  /// one saw this one's sessions or approved at the same time).
  final String? approval, approvedAfter;

  /// Events of sessions taken away that the device that took them away could not delete (its calendar is on another device, or it could
  /// not be reached); the next device that can reach them deletes them.
  final List<StrayEvent> strays;

  /// What was made for the parts (unit id -> summary points and number of cards, see [StudyMaterialMaker]).
  final Map<String, UnitMaterial> material;

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
    this.speed = 1,
    this.calendarDevice,
    this.approval,
    this.approvedAfter,
    this.strays = const [],
    this.material = const {},
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
    double? speed,
    String? Function()? calendarDevice,
    String? approval,
    String? approvedAfter,
    List<StrayEvent>? strays,
    Map<String, UnitMaterial>? material,
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
        speed: speed ?? this.speed,
        calendarDevice: calendarDevice == null ? this.calendarDevice : calendarDevice(),
        approval: approval ?? this.approval,
        approvedAfter: approvedAfter ?? this.approvedAfter,
        strays: strays ?? this.strays,
        material: material ?? this.material,
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
        if (speed != 1) 'speed': speed,
        if (calendarDevice != null) 'calDevice': calendarDevice,
        if (approval != null) 'approval': approval,
        if (approvedAfter != null) 'after': approvedAfter,
        if (strays.isNotEmpty) 'strays': _straysJson(strays),
        if (material.isNotEmpty) 'material': {for (final e in material.entries) e.key: e.value.toJson()},
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
      speed: (j['speed'] as num?)?.toDouble() ?? 1,
      calendarDevice: j['calDevice'] as String?,
      approval: j['approval'] as String?,
      approvedAfter: j['after'] as String?,
      strays: strayEventsOf(j['strays']),
      material: {
        for (final e in ((j['material'] as Map?) ?? const {}).entries)
          '${e.key}': ?UnitMaterial.fromJson(e.value),
      },
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

  /// Sessions that were studied with work left over.
  final int unfinished;

  /// Sessions to come whose event was deleted in the calendar app.
  final int removed;

  /// How long the person takes is not what the plan was made with any more: 1.25 is a quarter longer than then, 0.8 a fifth quicker
  /// (null: about the same).
  final double? pace;

  const PlanAttention({this.missed = 0, this.clashes = 0, this.dropped = 0, this.unbooked = false, this.unfinished = 0, this.removed = 0, this.pace});

  bool get any => missed > 0 || clashes > 0 || dropped > 0 || unbooked || unfinished > 0 || removed > 0 || pace != null;
}

/// The plans for exams. A plan is made from the material and the hours given, shown as a proposal and only put on the calendar (as
/// events, and as to-dos) once the person approves it. Ticking off a session's to-do counts its work as done. Sessions that were missed,
/// that clash with a new event or whose to-do was deleted are noticed ([attentionOf]); the plan is then proposed again, and again only
/// changed once approved.
class StudyPlanner extends ChangeNotifier {
  /// Each plan is kept under its own key, which syncs between the devices (one setting a plan: a change to one plan on one device and to
  /// another on another device are both kept). A plan that was deleted keeps its key with a mark, so that the deletion syncs too.
  static const planPrefix = 'study_plan:';

  /// Where the plans were kept before they synced (all in one key), read once and moved.
  static const _oldKey = 'study_plans';

  /// What is this device's only (not synced): the session being studied, the to-dos of sessions made here, and this device's own name
  /// for the plans (to tell which device a phone calendar is on).
  static const _runningKey = 'study_session_running';
  static const _hereKey = 'study_tasks_here';
  static const _deviceKey = 'study_device';

  /// The minutes of estimate the measured pace starts from, so that one session does not swing it (it counts as that much study at
  /// the estimated pace); and how far it may go.
  static const _paceWeight = 60;
  static const _slowest = 1.8, _quickest = 0.6;

  /// How much the pace must have changed since the plan was made before it is said.
  static const _paceNoticed = 0.15;

  /// How often the sessions' events are looked up in their calendar (each time is a reading of the server or the phone).
  static const _lookEvery = Duration(minutes: 15);

  final SettingsRepository _settings;
  final CardRepository _cards;
  final TaskRepository _tasks;
  final StudyCalendarAccess? calendar;

  /// What can be read about a note to cut it into units (null: it is gone).
  final Future<NoteShape?> Function(String noteId)? readNote;
  final DateTime Function() _now;
  List<StudyPlanEntry> _plans = [];
  RunningSession? _running;
  final Map<String, PlanAttention> _attention = {};
  StreamSubscription<void>? _sub;
  Timer? _soon, _daily;
  Future<void> _work = Future.value();

  /// Why the last approval could not write everything (null: it did).
  String? problem;

  /// The facts of the knowledge graphs, for the quizzes of the sessions (null: none; set once the graphs are there).
  StudyFactSource? facts;

  /// Makes the summaries and cards of a plan's parts (null: cannot).
  StudyMaterialMaker? maker;

  /// What cuts a run of pages by its topics with an AI model, where the person asks for it (null: no AI in this app).
  StudyTopicSplitter? topics;

  DateTime? _lookedAt;

  /// The plans as they were last kept (or came from another device), by id: only what changed is written again.
  final Map<String, String> _keptJson = {};

  /// Plans that were deleted and still have events to delete (that the device deleting the plan could not reach).
  final Map<String, List<StrayEvent>> _deletedStrays = {};

  /// The sessions' to-dos that were made on this device (or found here when plans began to sync). One missing from the to-dos was
  /// deleted here; one of a session that is not in this list was never made here, and is made.
  Set<String> _here = {};
  String _device = '';
  StreamSubscription<String>? _syncSub;

  StudyPlanner(this._settings, this._cards, this._tasks, {this.calendar, this.readNote, DateTime Function()? now}) : _now = now ?? DateTime.now;

  List<StudyPlanEntry> get plans => List.unmodifiable(_plans);

  /// The session that is being studied now (null: none).
  RunningSession? get running => _running;

  PlanAttention attentionOf(String planId) => _attention[planId] ?? const PlanAttention();

  /// Whether [taskId] is the to-do of a session (such a to-do is not put on the calendar a second time by the task mirror).
  bool ownsTask(String taskId) => _plans.any((p) => p.sessions.any((s) => s.taskId == taskId) || p.legacyTasks.containsValue(taskId));

  Future<void> load() async {
    _device = await _settings.get(_deviceKey) ?? '';
    if (_device.isEmpty) {
      _device = NoteRepository.newId();
      await _settings.set(_deviceKey, _device);
    }
    _plans = [];
    _keptJson.clear();
    _deletedStrays.clear();
    try {
      final rows = await _settings.allWhere((k) => k.startsWith(planPrefix));
      for (final r in rows.entries) {
        _keptJson[r.key.substring(planPrefix.length)] = r.value.value;
        final j = _decode(r.value.value);
        final e = StudyPlanEntry.fromJson(j);
        if (e != null) {
          _plans.add(e);
        } else if (j is Map && j['deleted'] == true) {
          final strays = strayEventsOf(j['strays']);
          if (strays.isNotEmpty) _deletedStrays[r.key.substring(planPrefix.length)] = strays;
        }
      }
    } catch (err) {
      debugPrint('reading the study plans failed: $err');
    }
    final old = await _settings.get(_oldKey);
    final moving = old != null;
    if (moving) {
      // (kept before plans synced: each gets its own key)
      try {
        for (final j in jsonDecode(old) as List) {
          final e = StudyPlanEntry.fromJson(j);
          if (e != null && !_keptJson.containsKey(e.id)) _plans.add(e);
        }
      } catch (_) {}
    }
    _plans.sort((a, b) => a.id.compareTo(b.id));
    final here = await _settings.get(_hereKey);
    if (here != null) {
      try {
        _here = {...(jsonDecode(here) as List).whereType<String>()};
      } catch (_) {
        _here = {};
      }
    } else {
      // (the plans were made here: all their to-dos are this device's)
      _here = {for (final p in _plans) ...[for (final s in p.sessions) ?s.taskId], for (final p in _plans) ...p.legacyTasks.values};
      await _saveHere();
    }
    // a plan in a phone calendar from before plans synced: the calendar is on this device
    _plans = [
      for (final p in _plans) p.target.key?.startsWith('phone:') == true && p.calendarDevice == null ? p.copyWith(calendarDevice: () => _device) : p,
    ];
    await _save();
    if (moving) await _settings.remove(_oldKey);
    try {
      final r = await _settings.get(_runningKey);
      _running = r == null ? null : RunningSession.fromJson(jsonDecode(r));
      if (_running != null && find(_running!.planId, _running!.key) == null) _running = null;
    } catch (_) {
      _running = null;
    }
    notifyListeners();
  }

  static Object? _decode(String v) {
    try {
      return jsonDecode(v);
    } catch (_) {
      return null;
    }
  }

  /// Starts keeping the plans up to date: when a to-do changed (a moment after), and once every few hours.
  void start({Duration every = const Duration(hours: 6)}) {
    _syncSub ??= _settings.changedBySync.listen((key) {
      if (key.startsWith(planPrefix)) unawaited(takeSynced(key.substring(planPrefix.length)));
    });
    _sub ??= _tasks.changes.listen((_) {
      _soon?.cancel();
      _soon = Timer(const Duration(seconds: 3), () => refresh());
    });
    _daily?.cancel();
    _daily = Timer.periodic(every, (_) => refresh());
    unawaited(refresh());
  }

  /// Keeps the plans that changed (each under its key), and marks those that are gone as deleted.
  Future<void> _save() async {
    final ids = <String>{};
    for (final p in _plans) {
      ids.add(p.id);
      final v = jsonEncode(p.toJson());
      if (_keptJson[p.id] == v) continue;
      _keptJson[p.id] = v;
      await _settings.set('$planPrefix${p.id}', v);
    }
    for (final id in [..._keptJson.keys]) {
      if (ids.contains(id)) continue;
      final strays = _deletedStrays[id] ?? const [];
      final v = jsonEncode({'id': id, 'deleted': true, if (strays.isNotEmpty) 'strays': _straysJson(strays)});
      if (_keptJson[id] == v) continue;
      _keptJson[id] = v;
      await _settings.set('$planPrefix$id', v);
    }
  }

  Future<void> _saveHere() => _settings.set(_hereKey, jsonEncode(_here.toList()..sort()));

  /// Whether the calendar [target] can be written and read from this device: a phone calendar only on the phone it is on ([device]); the
  /// calendar of a server on any device (whether it is connected there is found out when it is used).
  bool _canReach(String target, String? device) => !target.startsWith('phone:') || device == _device;

  /// Whether the sessions of [e] are put in their calendar from this device (when not, they are put there by the device the calendar is
  /// on, the next time it is used).
  bool writesCalendarOf(StudyPlanEntry e) {
    final key = e.target.key;
    return key == null || _canReach(key, e.calendarDevice ?? _device);
  }

  /// Takes the plan [id] as it came from another device (a sync replaced its key). It is put together with the plan as it is here: what
  /// was said about a session on either device is kept, and a plan approved here and there at the same time keeps the newer approval,
  /// with the events of the other one to be deleted. This device's to-dos are then made to match it.
  Future<void> takeSynced(String id) {
    _work = _work.then((_) => _takeSynced(id)).catchError((Object err) => debugPrint('taking a study plan from another device failed: $err'));
    return _work;
  }

  Future<void> _takeSynced(String id) async {
    final v = await _settings.get('$planPrefix$id');
    if (v == null || v == _keptJson[id]) return;
    _keptJson[id] = v;
    final j = _decode(v);
    final mine = _plans.where((p) => p.id == id).firstOrNull;
    final theirs = StudyPlanEntry.fromJson(j);
    if (theirs == null) {
      if (j is Map && j['deleted'] == true) {
        // deleted on the other device: its to-dos here go too (those still to do), and the events it could not delete are deleted here
        _plans = [for (final p in _plans) if (p.id != id) p];
        _attention.remove(id);
        final strays = strayEventsOf(j['strays']);
        if (strays.isNotEmpty) _deletedStrays[id] = strays;
        if (_running?.planId == id) {
          _running = null;
          await _saveRunning();
        }
      } else {
        await _save(); // (what came cannot be read: the plan here is kept, and sent again)
      }
    } else {
      final tasks = {for (final t in await _tasks.listTasks()) t.id: t};
      final e = _credit(mine == null ? theirs : _merge(mine, theirs), tasks);
      _plans = [...[for (final p in _plans) if (p.id != id) p], e]..sort((a, b) => a.id.compareTo(b.id));
      // the session being studied here may have been moved there: it is followed by its to-do
      final r = _running;
      if (r != null && r.planId == id && find(id, r.key) == null) {
        final was = mine?.sessions.where((s) => s.key == r.key).firstOrNull;
        final now = was?.taskId == null ? null : e.sessions.where((s) => s.taskId == was!.taskId).firstOrNull;
        _running = now == null ? null : RunningSession(id, now.key, r.started, pausedAt: r.pausedAt, pausedSeconds: r.pausedSeconds, checked: r.checked);
        await _saveRunning();
      }
      await _save();
    }
    await _matchTasks();
    await _refresh(false);
  }

  /// [mine] and [theirs] (two versions of one plan) put together. The newer approval wins (on the same approval, the version that came);
  /// the reports of sessions only one of them has are kept, and so are the times kept free on either. When the two were approved at the
  /// same time, the sessions of the one that lost lose their events too.
  StudyPlanEntry _merge(StudyPlanEntry mine, StudyPlanEntry theirs) {
    // (a plan from before plans synced has no approval: it counts as the first)
    String of(String? approval) => approval ?? '';
    final keepMine = of(mine.approval) != of(theirs.approval) && mine.approvedAfter != null && mine.approvedAfter == of(theirs.approval);
    final (win, lose) = keepMine ? (mine, theirs) : (theirs, mine);
    final reports = {for (final s in lose.sessions) if (s.report != null && s.taskId != null) s.taskId!: s.report!};
    var e = win;
    if (reports.isNotEmpty) {
      e = e.copyWith(sessions: [for (final s in e.sessions) s.report == null && reports[s.taskId] != null ? s.copyWith(report: reports[s.taskId]) : s]);
    }
    final extra = {for (final x in lose.material.entries) if (!e.material.containsKey(x.key) && e.unit(x.key) != null) x.key: x.value};
    if (extra.isNotEmpty) e = e.copyWith(material: {...e.material, ...extra});
    final blocked = [...e.blocked, for (final b in lose.blocked) if (!e.blocked.any((x) => x.start == b.start && x.end == b.end)) b];
    if (blocked.length != e.blocked.length) e = e.copyWith(blocked: blocked);
    final atOnce = of(win.approval) != of(lose.approval) && of(win.approvedAfter) != of(lose.approval) && of(lose.approvedAfter) != of(win.approval);
    if (atOnce) {
      final still = {for (final s in win.sessions) ?s.eventId};
      final strays = [
        ...e.strays,
        for (final s in lose.sessions)
          if (s.eventId != null && s.eventTarget != null && !still.contains(s.eventId) && s.session.start.isAfter(_now()) && !e.strays.any((x) => x.id == s.eventId))
            (id: s.eventId!, target: s.eventTarget!, device: s.eventTarget!.startsWith('phone:') ? lose.calendarDevice : null),
      ];
      if (strays.length != e.strays.length) e = e.copyWith(strays: strays);
    }
    return e;
  }

  /// Makes the to-dos on this device match the sessions: a session to come that has no to-do here yet gets one (under the id the plan has
  /// for it, so that the to-do is one to-do on a server the to-dos sync with), one that was studied on another device is ticked off here,
  /// one that was moved there is moved here, and the to-dos of sessions that are not in any plan any more go (when not done). A to-do that
  /// was made here and deleted is not made again (the plan says that it was dropped).
  Future<void> _matchTasks() async {
    final now = _now();
    final tasks = {for (final t in await _tasks.listTasks()) t.id: t};
    final wanted = <String>{};
    var changed = false;
    for (final p in _plans) {
      wanted.addAll(p.legacyTasks.values);
      for (final s in p.sessions) {
        final id = s.taskId;
        if (id == null) continue;
        wanted.add(id);
        final t = tasks[id];
        final studied = s.credited || s.report != null;
        if (t == null) {
          if (_here.contains(id) || studied || s.skipped || s.gone || !s.session.end.isAfter(now)) continue;
          try {
            await _tasks.createTask(_taskTitleOf(s.session, s.title), dueDate: _day(s.session.start), auto: true, id: id);
          } catch (err) {
            debugPrint('making the to-do of a study session failed: $err');
            continue;
          }
          _here.add(id);
          changed = true;
          continue;
        }
        if (_here.add(id)) changed = true;
        if (t.done) continue;
        if (studied) {
          await _tasks.setDone(id, true, announce: false);
        } else if (!s.gone && (t.dueDate == null || _day(t.dueDate!) != _day(s.session.start) || !t.title.startsWith(_clock(s.session.start)))) {
          await _tasks.updateTask(id, title: _taskTitleOf(s.session, s.title), dueDate: _day(s.session.start));
        }
      }
    }
    for (final id in [..._here]) {
      if (wanted.contains(id)) continue;
      final t = tasks[id];
      if (t != null && !t.done) await _tasks.deleteTask(id);
      _here.remove(id);
      changed = true;
    }
    if (changed) await _saveHere();
  }

  /// Does on the calendar of [e] what other devices could not (when it can be reached from here): deletes the events of sessions that
  /// were taken away there, and puts in the sessions to come that have no event yet (approved on a device the calendar is not on, or
  /// written while the calendar could not be reached).
  Future<StudyPlanEntry> _catchUp(StudyPlanEntry e, Map<String, Task> tasks, DateTime now) async {
    final cal = calendar;
    if (cal == null) return e;
    if (e.strays.isNotEmpty) {
      final left = [for (final x in e.strays) if (!_canReach(x.target, x.device) || !await _deleteEvent(x)) x];
      if (left.length != e.strays.length) e = e.copyWith(strays: left);
    }
    final key = e.target.key;
    if (key == null || !_canReach(key, e.calendarDevice)) return e;
    final missing = [
      for (final s in e.sessions)
        if (s.eventId == null && s.session.start.isAfter(now) && !s.gone && !s.skipped && !_done(s, tasks)) s,
    ];
    if (missing.isEmpty) return e;
    var sessions = e.sessions;
    for (final s in missing) {
      final String id;
      try {
        id = await cal.create(key, _event(e, s.session, s.title, uid: s.taskId == null ? null : '${s.taskId}-session'));
      } catch (err) {
        debugPrint('putting a study session on the calendar failed: $err');
        break; // (it cannot be reached now: later)
      }
      sessions = [for (final o in sessions) identical(o, s) ? s.copyWith(eventId: id, eventTarget: key) : o];
    }
    return identical(sessions, e.sessions) ? e : e.copyWith(sessions: sessions);
  }

  /// Deletes the stray event [x]; whether it is gone.
  Future<bool> _deleteEvent(StrayEvent x) async {
    try {
      await calendar!.delete(x.target, x.id);
      return true;
    } catch (err) {
      debugPrint('deleting the event of a study session failed: $err');
      return false;
    }
  }

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

  bool _done(BookedSession s, Map<String, Task> tasks) => s.credited || s.report != null || (s.taskId != null && tasks[s.taskId]?.done == true);

  /// The booked sessions of [e] that stay whatever the new plan is: those that began already, those that are done, and those the person
  /// moved in the calendar app ([_pinned]).
  List<BookedSession> _kept(StudyPlanEntry e, Map<String, Task> tasks) =>
      [for (final s in e.sessions) if (!s.session.start.isAfter(_now()) || _done(s, tasks) || _pinned(s, tasks)) s];

  /// A session to come that the person moved in the calendar app: it keeps its time and its work.
  bool _pinned(BookedSession s, Map<String, Task> tasks) => s.moved && !s.gone && s.session.start.isAfter(_now()) && !_done(s, tasks);

  /// [progress] with the work of [sessions] counted in (only the items that count: the said ones of a reported session).
  static Map<String, UnitProgress> _withWork(Map<String, UnitProgress> progress, Iterable<BookedSession> sessions) {
    final out = {...progress};
    for (final s in sessions) {
      for (final (n, i) in s.session.items.indexed) {
        if (s.report != null && !s.report!.done.contains(n)) continue;
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
    return out;
  }

  /// The sessions [e] would have now (from what is done, the calendars and the hours given), compared with what is booked.
  Future<StudyProposal> propose(StudyPlanEntry draft) async {
    var e = draft;
    final now = _now();
    final tasks = {for (final t in await _tasks.listTasks()) t.id: t};
    e = _credit(e, tasks);
    e = e.copyWith(speed: speedOf(e));
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
    final ownIds = [for (final s in e.sessions) if (s.eventId != null) s.eventId!];
    bool isOwn(DayEvent ev) => own.any((o) => o.$1 == ev.calendarKey && o.$2 == ev.start && (ev.end == null || o.$3 == ev.end)) || ownIds.any((id) => isEventOf(ev, id));
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
      // (the work of the sessions the person moved is where they put it: the rest is planned around it)
      progress: _withWork(e.progress, [for (final s in kept) if (_pinned(s, tasks)) s]),
      time: e.time,
      busy: busy,
      cardMinutes: await _cardMinutes(e),
      speed: e.speed,
      practice: await _practice(e),
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

  /// What there is to practise in the parts of [e]: the kept maths mistakes not known well yet, and whether a part has enough facts for
  /// a quiz (only when a quiz can be made now).
  Future<Map<String, UnitPractice>> _practice(StudyPlanEntry e) async {
    final cards = <ReviewCard>[];
    for (final id in {for (final u in e.units) if (u.included) u.noteId}) {
      cards.addAll(await _cards.all(source: id));
    }
    final spots = await _factSpots();
    // (a part with a summary has the points of it to make a quiz of, when a quiz can be made now)
    final canQuiz = facts?.canQuiz ?? false;
    bool quizOf(StudyUnit u) => factsIn(u, spots).length >= quizFacts || canQuiz && (e.material[u.id]?.points.length ?? 0) >= quizFacts;
    return {
      for (final u in e.units)
        if (u.included)
          if ((mistakes: mistakesIn(u, cards).length, quiz: quizOf(u)) case final p when p.mistakes > 0 || p.quiz) u.id: p,
    };
  }

  Future<List<FactSpot>> _factSpots() async {
    final source = facts;
    if (source == null || !source.canQuiz) return const [];
    try {
      return await source.facts();
    } catch (err) {
      debugPrint('reading the facts of the graphs for a study plan failed: $err');
      return const [];
    }
  }

  /// The maths mistakes of [u] to do again (see [mistakesIn]).
  Future<List<ReviewCard>> mistakesOf(StudyUnit u) async => mistakesIn(u, await _cards.all(source: u.noteId));

  /// The facts of [u] in the knowledge graphs, or else the points of its [material] (none when a quiz cannot be made now).
  Future<List<StudyFact>> factsOf(StudyUnit u, {UnitMaterial? material}) async {
    final graph = factsIn(u, await _factSpots());
    if (graph.length >= quizFacts || material == null || !(facts?.canQuiz ?? false)) return graph;
    return [for (final p in material.points) StudyFact(u.title, p)];
  }

  /// Whether summaries and cards can be made now.
  bool get canMakeMaterial => maker?.ready ?? false;

  /// The minutes each included part of [e] has in all, from now to the exam (see [shareMinutes]).
  Map<String, int> _shares(StudyPlanEntry e) {
    final units = [for (final u in e.units) if (u.included) u];
    return shareMinutes(
      today: _now(),
      exam: e.exam,
      daysOff: e.daysOff,
      perDay: e.maxPerDay,
      windowMinutes: math.max(0, e.windowEnd - e.windowStart),
      weights: {for (final u in units) u.id: u.learnMinutes},
    );
  }

  /// [e] with the summary and the flashcards made of the parts that have none yet (all parts with [again]), as much of each as the
  /// words of the part and the time to the exam call for ([materialBudget]). The cards are kept with the note's other cards (they
  /// are part of the plan's cards from then on) and the summaries go in the plan, which is kept once it is approved. A part with too
  /// little text read is left as it is. With [cancel] cancelled, what was made so far is kept. A [StateError] says why when nothing
  /// could be made.
  Future<({StudyPlanEntry entry, int units, int cards, int skipped})> makeMaterial(StudyPlanEntry e,
      {bool again = false, AiCancel? cancel, void Function(double done)? onProgress}) async {
    final m = maker;
    if (m == null || !m.ready) throw StateError(tr('No AI model is ready.'));
    m.forget();
    final shares = _shares(e);
    final todo = [for (final u in e.units) if (u.included && (again || !e.material.containsKey(u.id))) u];
    final material = {...e.material};
    var cards = 0, made = 0, skipped = 0;
    for (final (i, u) in todo.indexed) {
      if (cancel?.cancelled ?? false) break;
      final passages = await m.passagesOf(u);
      final budget = materialBudget(
        words: wordCount(passages.replaceAll(RegExp(r'\[Page \d+\]'), '')),
        learnMinutes: u.learnMinutes,
        reviewMinutes: u.reviewMinutes,
        minutesAvailable: shares[u.id] ?? 0,
      );
      if (budget.points == 0 && budget.cards == 0) {
        skipped++;
      } else {
        final r = await m.make(u, passages, budget, cancel: cancel);
        if (cancel?.cancelled ?? false) break;
        if (r.material.isEmpty) {
          skipped++;
        } else {
          material[u.id] = r.material;
          made++;
          if (r.cards.isNotEmpty) cards += await _cards.addAll(u.noteId, r.cards);
        }
      }
      onProgress?.call((i + 1) / todo.length);
    }
    if (made == 0 && skipped > 0 && todo.length == skipped) {
      throw StateError(tr('There is too little text on these pages to make anything of: their handwriting or their PDF may not have been read yet.'));
    }
    return (entry: e.copyWith(material: material), units: made, cards: cards, skipped: skipped);
  }

  /// [e] with the work of the sessions that were done counted in (once: such a session is marked as counted). A session studied with its
  /// screen counts the items that were said to be done; one whose to-do was ticked off counts all of them.
  StudyPlanEntry _credit(StudyPlanEntry e, Map<String, Task> tasks) {
    if (!e.sessions.any((s) => !s.credited && _done(s, tasks))) return e;
    final out = _withWork(e.progress, [for (final s in e.sessions) if (!s.credited && _done(s, tasks)) s]);
    return e.copyWith(progress: out, sessions: [for (final s in e.sessions) _done(s, tasks) ? s.copyWith(credited: true) : s]);
  }

  static String _taskTitleOf(PlannedSession s, String title) => '${_clock(s.start)} $title';

  NewEvent _event(StudyPlanEntry e, PlannedSession s, String title, {String? uid}) => NewEvent(
        title: title,
        start: s.start,
        end: s.end,
        uid: uid,
        description: [
          for (final i in s.items) '- ${itemText(i, i.unitId == null ? null : e.unit(i.unitId!))}',
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
    // (the events there are now are in the calendar of the plan as it was)
    final wasDevice = e.calendarDevice;
    final strays = [...e.strays];

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
    // a phone calendar is on the device it was picked on (the same calendar as before stays where it was)
    final device = target.key?.startsWith('phone:') != true ? null : (target.key == p.entry.target.key ? wasDevice ?? _device : _device);
    e = e.copyWith(target: target, calendarDevice: () => device);
    final writes = target.key != null && _canReach(target.key!, device);

    Future<void> unbook(BookedSession s) async {
      if (s.eventId != null && s.eventTarget != null) {
        final x = (id: s.eventId!, target: s.eventTarget!, device: s.eventTarget!.startsWith('phone:') ? wasDevice : null);
        // (one that cannot be deleted from here is deleted by the next device that can)
        if (cal == null || !_canReach(x.target, x.device) || !await _deleteEvent(x)) strays.add(x);
      }
      final t = s.taskId == null ? null : tasks[s.taskId];
      if (t != null && !t.done) await _tasks.deleteTask(t.id);
    }

    Future<({String? id, String? target})> write(ProposedSession s, String taskId) async {
      final key = target.key;
      if (key == null || cal == null || !writes) return (id: null, target: null);
      try {
        return (id: await cal.create(key, _event(e, s.session, s.title, uid: '$taskId-session')), target: key);
      } catch (err) {
        errors.add('$err'.replaceFirst('Bad state: ', ''));
        return (id: null, target: null);
      }
    }

    // the sessions that stay: those that began and those that are done; one that went by undone (or left work) is not reported again
    final kept = [for (final s in _kept(e, tasks)) s.credited && !s.unfinished || _pinned(s, tasks) ? s : s.copyWith(skipped: true)];
    final booked = {for (final s in e.sessions) if (!kept.any((k) => k.key == s.key)) s.key: s};
    for (final s in p.removed) {
      await unbook(s);
      booked.remove(s.key);
    }
    final next = <BookedSession>[...kept];
    for (final s in p.sessions) {
      final old = booked.remove(s.session.key);
      // (a session still without its event keeps waiting for it when this device does not write to the calendar)
      if (old != null &&
          s.change == SessionChange.same &&
          (old.eventTarget == target.key || old.eventTarget == null && (target.key == null || !writes)) &&
          (old.eventId != null || target.key == null || !writes)) {
        next.add(old);
        continue;
      }
      if (old != null) await unbook(old);
      final taskId = await _tasks.createTask(_taskTitleOf(s.session, s.title), dueDate: _day(s.session.start), auto: true);
      _here.add(taskId);
      final ev = await write(s, taskId);
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
    final before = _plans.where((x) => x.id == e.id).firstOrNull;
    e = e.copyWith(sessions: next, legacyTasks: const {}, strays: strays, approval: NoteRepository.newId(), approvedAfter: before?.approval ?? '');
    final i = _plans.indexWhere((x) => x.id == e.id);
    _plans = i < 0 ? [..._plans, e] : [for (final x in _plans) x.id == e.id ? e : x];
    _attention.remove(e.id);
    if (errors.isNotEmpty) problem = errors.toSet().join('\n');
    await _saveHere();
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
    final strays = [...entry.strays];
    for (final s in entry.sessions) {
      if (!s.session.start.isAfter(now)) continue;
      final t = s.taskId == null ? null : tasks[s.taskId];
      if (t?.done == true || s.credited || s.report != null) continue;
      if (s.eventId != null && s.eventTarget != null) {
        final x = (id: s.eventId!, target: s.eventTarget!, device: s.eventTarget!.startsWith('phone:') ? entry.calendarDevice : null);
        // (one that cannot be deleted from here is deleted by the next device that can: it goes with the mark that the plan was deleted)
        if (calendar == null || !_canReach(x.target, x.device) || !await _deleteEvent(x)) strays.add(x);
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
    if (strays.isNotEmpty) _deletedStrays[id] = strays;
    await _matchTasks();
    await _save();
    notifyListeners();
  }

  /// Counts the work of sessions whose to-do was ticked off, drops plans whose exam is over, follows the sessions whose event was moved
  /// in the calendar app (at most every few minutes, or now with [lookAtCalendar]) and notices what wants the plan made again. Nothing
  /// on the calendar is changed here.
  Future<void> refresh({bool lookAtCalendar = false}) {
    _work = _work.then((_) => _refresh(lookAtCalendar)).catchError((Object err) => debugPrint('refreshing the study plans failed: $err'));
    return _work;
  }

  Future<void> _refresh(bool lookAtCalendar) async {
    final now = _now();
    final today = _day(now);
    await _matchTasks();
    final tasks = {for (final t in await _tasks.listTasks()) t.id: t};
    final look = calendar != null && (lookAtCalendar || _lookedAt == null || now.difference(_lookedAt!) >= _lookEvery);
    if (look) {
      _lookedAt = now;
      // the events of plans deleted on a device that could not delete them
      for (final id in [..._deletedStrays.keys]) {
        final left = [for (final x in _deletedStrays[id]!) if (!_canReach(x.target, x.device) || !await _deleteEvent(x)) x];
        if (left.isEmpty) {
          _deletedStrays.remove(id);
        } else {
          _deletedStrays[id] = left;
        }
      }
    }
    final next = <StudyPlanEntry>[];
    for (final e in _plans) {
      if (e.exam.isBefore(today)) {
        _attention.remove(e.id); // (the exam is over)
        continue;
      }
      var entry = _credit(e, tasks);
      if (look) entry = await _catchUp(await _followCalendar(entry, tasks, now), tasks, now);
      next.add(entry);
      final upcoming = [for (final s in entry.sessions) if (s.session.start.isAfter(now) && !s.credited && !s.gone) s];
      var clashes = 0;
      if (calendar != null && upcoming.isNotEmpty) {
        try {
          final events = await calendar!.events(today, DateTime(entry.exam.year, entry.exam.month, entry.exam.day + 1));
          for (final s in upcoming) {
            if (events.any((ev) =>
                !ev.allDay &&
                !(ev.calendarKey == s.eventTarget && ev.start == s.session.start) &&
                !entry.sessions.any((o) => o.eventId != null && isEventOf(ev, o.eventId!)) &&
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
        dropped: upcoming.where((s) => s.taskId != null && _here.contains(s.taskId) && !tasks.containsKey(s.taskId)).length,
        clashes: clashes,
        unbooked: entry.sessions.isEmpty,
        unfinished: entry.sessions.where((s) => s.unfinished && !s.skipped).length,
        removed: entry.sessions.where((s) => s.gone && !s.skipped && s.session.end.isAfter(now)).length,
        pace: _paceChange(entry, upcoming.isNotEmpty),
      );
    }
    _plans = next;
    // (a deleted plan's mark without strays left is written again)
    await _save();
    notifyListeners();
  }

  /// [e] with what was done to its sessions' events in the calendar app: a session whose event was moved goes with it (its to-do is
  /// moved too), one whose event was deleted is marked [BookedSession.gone] and its time is kept free ([StudyPlanEntry.blocked]) for when
  /// the plan is made again. Only the sessions to come that were not studied yet are looked at, and only in calendars that can be read now.
  Future<StudyPlanEntry> _followCalendar(StudyPlanEntry e, Map<String, Task> tasks, DateTime now) async {
    final watched = [
      for (final s in e.sessions)
        if (s.eventId != null &&
            s.eventTarget != null &&
            _canReach(s.eventTarget!, e.calendarDevice) &&
            !s.gone &&
            s.session.start.isAfter(now) &&
            !_done(s, tasks))
          s,
    ];
    if (watched.isEmpty) return e;
    final from = _day(now).subtract(const Duration(days: 7)), to = DateTime(e.exam.year, e.exam.month, e.exam.day + 14);
    final read = <String, List<DayEvent>?>{};
    for (final target in {for (final s in watched) s.eventTarget!}) {
      try {
        read[target] = await calendar!.eventsIn(target, from, to);
      } catch (err) {
        debugPrint('reading the calendar of a study plan failed: $err');
      }
    }
    var sessions = e.sessions;
    var blocked = e.blocked;
    for (final s in watched) {
      final events = read[s.eventTarget];
      if (events == null) continue; // (it cannot be read now: nothing is said)
      final ev = events.where((ev) => isEventOf(ev, s.eventId!)).firstOrNull;
      BookedSession? changedTo;
      if (ev == null || ev.allDay) {
        changedTo = s.copyWith(gone: true);
        blocked = [...blocked, (start: s.session.start, end: s.session.end)];
      } else {
        final end = ev.end ?? ev.start.add(Duration(minutes: s.session.minutes));
        final minutes = math.max(5, end.difference(ev.start).inMinutes);
        if (ev.start == s.session.start && minutes == s.session.minutes) continue;
        final moved = PlannedSession(ev.start, minutes, s.session.items);
        if (moved.key != s.key && sessions.any((o) => o.key == moved.key)) continue; // (onto another session of the plan: left as it is)
        changedTo = s.copyWith(session: moved, moved: true);
        final t = s.taskId == null ? null : tasks[s.taskId];
        if (t != null && !t.done) await _tasks.updateTask(t.id, title: '${_clock(moved.start)} ${s.title}', dueDate: _day(moved.start));
        if (_running?.planId == e.id && _running?.key == s.key) {
          _running = RunningSession(e.id, moved.key, _running!.started, pausedAt: _running!.pausedAt, pausedSeconds: _running!.pausedSeconds, checked: _running!.checked);
          await _saveRunning();
        }
      }
      sessions = [for (final o in sessions) identical(o, s) ? changedTo : o]..sort((a, b) => a.session.start.compareTo(b.session.start));
    }
    return identical(sessions, e.sessions) ? e : e.copyWith(sessions: sessions, blocked: blocked);
  }

  /// How long the person takes compared with the estimates of [e], from the sessions studied with their screen: the minutes spent
  /// against the minutes planned for what was done. It starts at 1 and moves as sessions are reported, within limits.
  double speedOf(StudyPlanEntry e) {
    var spent = 0, planned = 0;
    for (final s in e.sessions) {
      final r = s.report;
      if (r == null || r.done.isEmpty) continue;
      spent += r.spent;
      for (final (n, i) in s.session.items.indexed) {
        if (r.done.contains(n)) planned += i.minutes;
      }
    }
    if (planned == 0) return 1;
    final speed = ((spent + _paceWeight) / (planned + _paceWeight)).clamp(_quickest, _slowest);
    return (speed * 100).round() / 100;
  }

  double? _paceChange(StudyPlanEntry e, bool sessionsToCome) {
    if (!sessionsToCome) return null;
    final change = speedOf(e) / e.speed;
    return (change - 1).abs() > _paceNoticed ? change : null;
  }

  /// The plan and the session of [key] in it.
  ({StudyPlanEntry plan, BookedSession session})? find(String planId, String key) {
    final plan = _plans.where((p) => p.id == planId).firstOrNull;
    final session = plan?.sessions.where((s) => s.key == key).firstOrNull;
    return session == null ? null : (plan: plan!, session: session);
  }

  /// The session whose to-do is [taskId].
  ({StudyPlanEntry plan, BookedSession session})? findByTask(String taskId) {
    for (final p in _plans) {
      for (final s in p.sessions) {
        if (s.taskId == taskId) return (plan: p, session: s);
      }
    }
    return null;
  }

  /// When the session of the to-do [taskId] starts, for its reminder (null: it is not a session's to-do, or the session was studied).
  DateTime? startOfTask(String taskId) {
    final f = findByTask(taskId);
    return f == null || f.session.report != null || f.session.credited || f.session.gone ? null : f.session.session.start;
  }

  /// The session to offer now: the one that is being studied, or else today's next one that is not over (by more than an hour) and was
  /// not studied yet.
  ({StudyPlanEntry plan, BookedSession session})? current() {
    final r = _running;
    if (r != null) {
      final f = find(r.planId, r.key);
      if (f != null) return f;
    }
    final now = _now();
    ({StudyPlanEntry plan, BookedSession session})? best;
    for (final p in _plans) {
      for (final s in p.sessions) {
        final start = s.session.start;
        if (s.credited || s.report != null || s.skipped || s.gone) continue;
        if (_day(start) != _day(now) || s.session.end.add(const Duration(hours: 1)).isBefore(now)) continue;
        if (best == null || start.isBefore(best.session.session.start)) best = (plan: p, session: s);
      }
    }
    return best;
  }

  Future<void> _saveRunning() async {
    final r = _running;
    if (r == null) {
      await _settings.remove(_runningKey);
    } else {
      await _settings.set(_runningKey, jsonEncode(r.toJson()));
    }
  }

  /// Starts the clock of a session (another that was running is let go: one is studied at a time).
  Future<void> begin(String planId, String key) async {
    if (_running?.planId == planId && _running?.key == key) return;
    _running = RunningSession(planId, key, _now());
    await _saveRunning();
    notifyListeners();
  }

  /// Stops the clock for a while, or lets it run again.
  Future<void> pause(bool pause) async {
    final r = _running;
    if (r == null || r.paused == pause) return;
    final now = _now();
    _running = pause ? r._with(pausedAt: () => now) : r._with(pausedAt: () => null, pausedSeconds: r.pausedSeconds + now.difference(r.pausedAt!).inSeconds);
    await _saveRunning();
    notifyListeners();
  }

  /// Ticks off the item [index] of the running session, or takes the tick back.
  Future<void> check(int index, bool done) async {
    final r = _running;
    if (r == null) return;
    _running = r._with(checked: done ? {...r.checked, index} : ({...r.checked}..remove(index)));
    await _saveRunning();
    notifyListeners();
  }

  /// Lets go of the running session without saying anything about it.
  Future<void> abandon() async {
    _running = null;
    await _saveRunning();
    notifyListeners();
  }

  /// Ends the session [key] of the plan [planId] with what was said about it: its to-do is ticked off, the items that were done count,
  /// and the parts it was about become a step harder (it felt hard) or easier (it felt easy). Returns the parts whose difficulty changed.
  /// The plan is not made again here; the plan says when it should be ([attentionOf]).
  Future<List<StudyUnit>> finish(String planId, String key, SessionReport report) async {
    final f = find(planId, key);
    if (f == null) return const [];
    var e = f.plan;
    final s = f.session;
    if (s.taskId != null) {
      final t = (await _tasks.listTasks()).where((t) => t.id == s.taskId).firstOrNull;
      if (t != null && !t.done) await _tasks.setDone(t.id, true);
    }
    final changed = <StudyUnit>[];
    if (report.feeling != SessionFeeling.fine) {
      final ids = {
        for (final (n, i) in s.session.items.indexed)
          if (report.done.contains(n) && i.unitId != null && (i.kind == WorkKind.learn || i.kind == WorkKind.review)) i.unitId!,
      };
      final step = report.feeling == SessionFeeling.hard ? 1 : -1;
      final units = <StudyUnit>[];
      for (final u in e.units) {
        final to = u.difficulty.index + step;
        if (ids.contains(u.id) && to >= 0 && to < Difficulty.values.length) {
          changed.add(u.copyWith(difficulty: Difficulty.values[to]));
          units.add(changed.last);
        } else {
          units.add(u);
        }
      }
      e = e.copyWith(units: units);
    }
    e = e.copyWith(sessions: [for (final x in e.sessions) x.key == key ? x.copyWith(report: report) : x]);
    e = _credit(e, {for (final t in await _tasks.listTasks()) t.id: t});
    _plans = [for (final p in _plans) p.id == planId ? e : p];
    if (_running?.planId == planId && _running?.key == key) {
      _running = null;
      await _saveRunning();
    }
    await _save();
    notifyListeners();
    await refresh();
    return changed;
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    _sub?.cancel();
    _soon?.cancel();
    _daily?.cancel();
    super.dispose();
  }
}
