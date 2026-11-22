import 'dart:math' as math;

import 'study_material.dart';
import 'study_planner.dart';
import 'study_schedule.dart';

/// How a plan stands against its own schedule.
enum PlanPace { onTrack, ahead, behind }

/// How far a plan is: how ready the person is for the exam, whether that is as far as the sessions that are over promised, and what
/// comes next. Worked out from the plan alone (its parts, what is done of them and its booked sessions).
class PlanProgress {
  /// How ready the material is (0..1): a part that was learnt but not gone over counts [learnShare], one that was gone over as well
  /// counts all of it; weighed by how long each part takes to learn. 0 for a plan without parts.
  final double readiness;

  /// What the sessions that are over promised (0..1), counted the same way.
  final double planned;

  /// Whether the plan has parts to be ready in (a plan that goes by the flashcards only has none).
  final bool hasParts;

  final PlanPace pace;

  /// How many sessions that are over were not done (not counting ones that were taken out of the calendar or made again).
  final int missed;

  /// The days to the exam (0: today) and the minutes of the sessions to come.
  final int daysLeft;
  final int minutesLeft;

  /// The sessions done and all of them.
  final int sessionsDone, sessionsAll;

  /// The next session to do (the one being studied now counts), null when there is none.
  final BookedSession? next;

  const PlanProgress({
    required this.readiness,
    required this.planned,
    required this.hasParts,
    required this.pace,
    required this.missed,
    required this.daysLeft,
    required this.minutesLeft,
    required this.sessionsDone,
    required this.sessionsAll,
    required this.next,
  });

  /// How much of a part counts once it was learnt (the going-over gives the rest).
  static const learnShare = 0.6;

  /// How far ahead or behind (in readiness) is still "on track".
  static const slack = 0.03;

  static double _ready(StudyPlanEntry e, Map<String, UnitProgress> progress) {
    final parts = e.units.where((u) => u.included).toList();
    final all = parts.fold<int>(0, (n, u) => n + u.learnMinutes);
    if (all == 0) return 0;
    var sum = 0.0;
    for (final u in parts) {
      final p = progress[u.id];
      if (p == null) continue;
      final learned = p.learned.clamp(0.0, 1.0);
      // going over what was not learnt yet does not make it known
      final reviewed = p.reviewed.clamp(0.0, learned);
      sum += u.learnMinutes * (learnShare * learned + (1 - learnShare) * reviewed);
    }
    return (sum / all).clamp(0.0, 1.0);
  }

  /// A part's own readiness (0..1), the same way as for the plan.
  static double partReady(UnitProgress? p) {
    if (p == null) return 0;
    final learned = p.learned.clamp(0.0, 1.0);
    return learnShare * learned + (1 - learnShare) * p.reviewed.clamp(0.0, learned);
  }

  /// [e] as it stands at [now].
  factory PlanProgress.of(StudyPlanEntry e, DateTime now, {BookedSession? current}) {
    final today = DateTime(now.year, now.month, now.day);
    final days = DateTime(e.exam.year, e.exam.month, e.exam.day).difference(today).inDays;
    // what the sessions that are over promised: their work, but not that of sessions the person took out or that were made again
    final promised = <String, UnitProgress>{};
    var missed = 0;
    for (final s in e.sessions) {
      if (s.gone || s.skipped || s.session.end.isAfter(now)) continue;
      if (!s.credited) missed++;
      for (final i in s.session.items) {
        final id = i.unitId;
        if (id == null) continue;
        final p = promised[id] ?? (learned: 0.0, reviewed: 0.0);
        final share = i.to - i.from;
        promised[id] = switch (i.kind) {
          WorkKind.learn => (learned: (p.learned + share).clamp(0.0, 1.0), reviewed: p.reviewed),
          WorkKind.review => (learned: p.learned, reviewed: (p.reviewed + share).clamp(0.0, 1.0)),
          _ => p,
        };
      }
    }
    final readiness = _ready(e, e.progress);
    final planned = _ready(e, promised);
    final gap = readiness - planned;
    final pace = gap > slack ? PlanPace.ahead : (gap < -slack ? PlanPace.behind : PlanPace.onTrack);
    final coming = [...e.sessions.where((s) => !s.credited && !s.gone && s.session.end.isAfter(now))]..sort((a, b) => a.session.start.compareTo(b.session.start));
    return PlanProgress(
      readiness: readiness,
      planned: planned,
      hasParts: e.units.any((u) => u.included),
      pace: pace,
      missed: missed,
      daysLeft: days < 0 ? 0 : days,
      minutesLeft: coming.fold<int>(0, (n, s) => n + s.session.minutes),
      sessionsDone: e.sessions.where((s) => s.credited).length,
      sessionsAll: e.sessions.where((s) => !s.gone).length,
      next: current ?? coming.firstOrNull,
    );
  }

  /// How ready the plan is at the end of each day from its first session to the exam: what the sessions promise ([ProgressPoint.planned])
  /// and what was done ([ProgressPoint.actual], only up to [now]: null after it).
  static List<ProgressPoint> curve(StudyPlanEntry e, DateTime now) {
    final sessions = e.sessions.where((s) => !s.gone).toList();
    if (sessions.isEmpty || !e.units.any((u) => u.included)) return const [];
    DateTime day(DateTime t) => DateTime(t.year, t.month, t.day);
    final today = day(now);
    var first = sessions.map((s) => day(s.session.start)).reduce((a, b) => a.isBefore(b) ? a : b);
    if (first.isAfter(today)) first = today;
    var last = day(e.exam);
    if (last.isBefore(first)) last = first;
    final planned = <String, UnitProgress>{}, actual = <String, UnitProgress>{};
    void add(Map<String, UnitProgress> to, SessionItem i) {
      final id = i.unitId;
      if (id == null) return;
      final p = to[id] ?? (learned: 0.0, reviewed: 0.0);
      final share = i.to - i.from;
      to[id] = switch (i.kind) {
        WorkKind.learn => (learned: (p.learned + share).clamp(0.0, 1.0), reviewed: p.reviewed),
        WorkKind.review => (learned: p.learned, reviewed: (p.reviewed + share).clamp(0.0, 1.0)),
        _ => p,
      };
    }

    final out = <ProgressPoint>[];
    for (var d = first; !d.isAfter(last); d = DateTime(d.year, d.month, d.day + 1)) {
      for (final s in sessions.where((s) => day(s.session.start) == d)) {
        if (!s.skipped || s.credited) {
          for (final i in s.session.items) {
            add(planned, i);
          }
        }
        if (s.credited) {
          for (final (n, i) in s.session.items.indexed) {
            if (s.report == null || s.report!.done.contains(n)) add(actual, i);
          }
        }
      }
      out.add(ProgressPoint(d, _ready(e, planned), d.isAfter(today) ? null : (d == today ? math.max(_ready(e, actual), _ready(e, e.progress)) : _ready(e, actual))));
    }
    return out;
  }
}

/// Work on a part: what kind of work, and the share of the part.
typedef PartWork = ({StudyUnit? unit, WorkKind kind, double share});

/// The work on parts that lies between [day] and today: for a day to come, what the sessions from today up to the end of [day] still have
/// to do ([ahead] is true); for a day that is over, what was done in the sessions after [day] up to now. Work of the same part and kind
/// is added up.
({bool ahead, List<PartWork> work}) workAround(StudyPlanEntry e, DateTime now, DateTime day) {
  DateTime d0(DateTime t) => DateTime(t.year, t.month, t.day);
  final today = d0(now), target = d0(day);
  final ahead = !target.isBefore(today);
  final sums = <(String, WorkKind), double>{};
  for (final s in e.sessions) {
    if (s.gone) continue;
    final sd = d0(s.session.start);
    if (ahead) {
      if (s.credited || s.skipped || sd.isBefore(today) || sd.isAfter(target)) continue;
    } else {
      if (!s.credited || !sd.isAfter(target) || sd.isAfter(today)) continue;
    }
    for (final (n, i) in s.session.items.indexed) {
      if (i.unitId == null) continue;
      if (!ahead && s.report != null && !s.report!.done.contains(n)) continue;
      sums[(i.unitId!, i.kind)] = (sums[(i.unitId!, i.kind)] ?? 0) + (i.to - i.from);
    }
  }
  return (ahead: ahead, work: [for (final en in sums.entries) (unit: e.unit(en.key.$1), kind: en.key.$2, share: en.value.clamp(0.0, 1.0))]);
}

/// One day of the curve of a plan.
class ProgressPoint {
  final DateTime day;
  final double planned;
  final double? actual;

  const ProgressPoint(this.day, this.planned, this.actual);
}
