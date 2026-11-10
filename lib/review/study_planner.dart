import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/card_repository.dart';
import '../data/settings_repository.dart';
import '../data/task_repository.dart';
import 'study_plan.dart';

/// A plan for an exam: which cards, when, how much time a day, and the tasks it made on the calendar (by day).
class StudyPlanEntry {
  final String id;
  final String name;

  /// The source of the cards (a note); null: all the cards.
  final String? source;

  /// The day of the exam.
  final DateTime exam;
  final int minutes;

  /// Weekdays (1 = Monday) without a session.
  final Set<int> daysOff;

  /// The task of each day (`2026-06-01`).
  final Map<String, String> tasks;

  const StudyPlanEntry({required this.id, required this.name, this.source, required this.exam, this.minutes = 20, this.daysOff = const {}, this.tasks = const {}});

  StudyPlanEntry copyWith({Map<String, String>? tasks}) => StudyPlanEntry(id: id, name: name, source: source, exam: exam, minutes: minutes, daysOff: daysOff, tasks: tasks ?? this.tasks);

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'source': source,
        'exam': dayKey(exam),
        'minutes': minutes,
        'off': daysOff.toList(),
        'tasks': tasks,
      };

  static StudyPlanEntry? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['exam'] is! String) return null;
    final exam = DateTime.tryParse(j['exam'] as String);
    if (exam == null) return null;
    return StudyPlanEntry(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? '',
      source: j['source'] as String?,
      exam: DateTime(exam.year, exam.month, exam.day),
      minutes: (j['minutes'] as num?)?.toInt() ?? 20,
      daysOff: {for (final d in (j['off'] as List?) ?? const []) if (d is int && d >= 1 && d <= 7) d},
      tasks: {for (final e in ((j['tasks'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
    );
  }
}

String dayKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// The plans for exams: from the day of the exam it works backwards and puts a short session on each day of the calendar (a task), and
/// makes the plan again every day and whenever cards were answered, so that the sessions follow what was got right.
class StudyPlanner extends ChangeNotifier {
  static const _key = 'study_plans';

  final SettingsRepository _settings;
  final CardRepository _cards;
  final TaskRepository _tasks;
  final DateTime Function() _now;
  List<StudyPlanEntry> _plans = [];
  StreamSubscription<void>? _sub;
  Timer? _soon, _daily;
  Future<void> _work = Future.value();

  StudyPlanner(this._settings, this._cards, this._tasks, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  List<StudyPlanEntry> get plans => List.unmodifiable(_plans);

  Future<void> load() async {
    try {
      _plans = [for (final j in jsonDecode(await _settings.get(_key) ?? '[]') as List) ?StudyPlanEntry.fromJson(j)];
    } catch (_) {
      _plans = [];
    }
    notifyListeners();
  }

  /// Starts keeping the plans up to date: when cards were answered (a moment after), and once every few hours.
  void start({Duration every = const Duration(hours: 6)}) {
    _sub ??= _cards.changes.listen((_) {
      _soon?.cancel();
      _soon = Timer(const Duration(seconds: 5), () => refresh());
    });
    _daily?.cancel();
    _daily = Timer.periodic(every, (_) => refresh());
    unawaited(refresh());
  }

  Future<void> _save() => _settings.set(_key, jsonEncode([for (final p in _plans) p.toJson()]));

  /// A new plan; its sessions are on the calendar when this returns.
  Future<StudyPlanEntry> create({required String name, String? source, required DateTime exam, int minutes = 20, Set<int> daysOff = const {}}) async {
    final entry = StudyPlanEntry(
      id: '${_now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? 'Exam' : name.trim(),
      source: source,
      exam: DateTime(exam.year, exam.month, exam.day),
      minutes: minutes.clamp(5, 240),
      daysOff: daysOff,
    );
    _plans = [..._plans, entry];
    await _save();
    notifyListeners();
    await refresh();
    return _plans.firstWhere((p) => p.id == entry.id);
  }

  /// Takes the plan away, with the sessions that are still to come (a session that was done stays).
  Future<void> remove(String id) async {
    final entry = _plans.where((p) => p.id == id).firstOrNull;
    if (entry == null) return;
    final done = {for (final t in await _tasks.listTasks()) if (t.done) t.id};
    final today = dayKey(_now());
    for (final e in entry.tasks.entries) {
      if (e.key.compareTo(today) >= 0 && !done.contains(e.value)) await _tasks.deleteTask(e.value);
    }
    _plans = [for (final p in _plans) if (p.id != id) p];
    await _save();
    notifyListeners();
  }

  /// How many cards each source (a note) has.
  Future<Map<String, int>> sourceCounts() => _cards.sourceCounts();

  /// The plan as it is now, from where the cards stand.
  Future<StudyPlan> planOf(StudyPlanEntry e) async =>
      planStudy(today: _now(), exam: e.exam, stats: await _cards.stats(source: e.source, now: _now()), minutesPerDay: e.minutes, daysOff: e.daysOff);

  /// Makes every plan again and brings the calendar in line: a session changed for the cards as they are, one that is not needed any more
  /// taken away, a new one added. Past days and sessions that are done are left alone. A plan whose exam is over is dropped.
  Future<void> refresh() {
    _work = _work.then((_) => _refresh()).catchError((Object _) {});
    return _work;
  }

  Future<void> _refresh() async {
    final today = dayKey(_now());
    final byId = {for (final t in await _tasks.listTasks()) t.id: t};
    var changed = false;
    final next = <StudyPlanEntry>[];
    for (final e in _plans) {
      if (dayKey(e.exam).compareTo(today) < 0) {
        changed = true; // the exam is over
        continue;
      }
      final plan = await planOf(e);
      final tasks = {...e.tasks};
      final wanted = <String>{};
      for (final s in plan.sessions) {
        final key = dayKey(s.day);
        wanted.add(key);
        final title = sessionTitle(e.name, s);
        final id = tasks[key];
        final existing = id == null ? null : byId[id];
        if (existing == null) {
          tasks[key] = await _tasks.createTask(title, dueDate: s.day, auto: true);
          changed = true;
        } else if (!existing.done && existing.title != title) {
          await _tasks.updateTask(existing.id, title: title, dueDate: s.day);
          changed = true;
        }
      }
      for (final key in tasks.keys.toList()) {
        if (wanted.contains(key) || key.compareTo(today) < 0) continue;
        final existing = byId[tasks[key]];
        if (existing != null && !existing.done) await _tasks.deleteTask(existing.id);
        if (existing == null || !existing.done) tasks.remove(key);
        changed = true;
      }
      next.add(e.copyWith(tasks: tasks));
    }
    _plans = next;
    if (changed) {
      await _save();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _soon?.cancel();
    _daily?.cancel();
    super.dispose();
  }
}
