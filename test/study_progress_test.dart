import 'package:flutter_test/flutter_test.dart';
import 'package:notes/review/study_material.dart';
import 'package:notes/review/study_planner.dart';
import 'package:notes/review/study_progress.dart';
import 'package:notes/review/study_schedule.dart';

void main() {
  const a = StudyUnit(id: 'a', noteId: 'n', title: 'A', minutes: 30);
  const b = StudyUnit(id: 'b', noteId: 'n', title: 'B', minutes: 30);
  final now = DateTime(2026, 11, 22, 12);

  BookedSession session(DateTime start, String unit, {WorkKind kind = WorkKind.learn, bool credited = false, bool gone = false, bool skipped = false}) =>
      BookedSession(PlannedSession(start, 30, [SessionItem(kind, unitId: unit, minutes: 30)]), 'S', credited: credited, gone: gone, skipped: skipped);

  StudyPlanEntry plan({Map<String, UnitProgress> progress = const {}, List<BookedSession> sessions = const []}) =>
      StudyPlanEntry(id: 'p', name: 'P', exam: DateTime(2026, 12, 2), units: const [a, b], progress: progress, sessions: sessions);

  test('learning counts 60 %, going over it as well counts all of it, and a part that was not learnt is not helped by a review', () {
    expect(PlanProgress.of(plan(), now).readiness, 0);
    expect(PlanProgress.of(plan(progress: {'a': (learned: 1.0, reviewed: 0.0)}), now).readiness, closeTo(0.3, 1e-9));
    expect(PlanProgress.of(plan(progress: {'a': (learned: 1.0, reviewed: 1.0), 'b': (learned: 1.0, reviewed: 1.0)}), now).readiness, closeTo(1, 1e-9));
    expect(PlanProgress.of(plan(progress: {'a': (learned: 0.0, reviewed: 1.0)}), now).readiness, 0);
  });

  test('a plan without parts has none to be ready in', () {
    final p = PlanProgress.of(StudyPlanEntry(id: 'p', name: 'P', exam: DateTime(2026, 12, 2)), now);
    expect(p.hasParts, isFalse);
    expect(p.readiness, 0);
  });

  test('on track, ahead and behind are told from what the sessions that are over promised', () {
    final over = now.subtract(const Duration(days: 1));
    final late = [session(over, 'a'), session(over.add(const Duration(hours: 1)), 'b')];
    // nothing done of two sessions that are over: behind, and both are counted as missed
    final behind = PlanProgress.of(plan(sessions: late), now);
    expect(behind.pace, PlanPace.behind);
    expect(behind.missed, 2);
    // both done
    final done = PlanProgress.of(plan(progress: {'a': (learned: 1.0, reviewed: 0.0), 'b': (learned: 1.0, reviewed: 0.0)}, sessions: [for (final s in late) s.copyWith(credited: true)]), now);
    expect(done.pace, PlanPace.onTrack);
    expect(done.missed, 0);
    // more done than promised
    final ahead = PlanProgress.of(plan(progress: {'a': (learned: 1.0, reviewed: 1.0), 'b': (learned: 1.0, reviewed: 0.0)}, sessions: [late.first.copyWith(credited: true)]), now);
    expect(ahead.pace, PlanPace.ahead);
  });

  test('sessions taken out of the calendar or made again do not count against the person', () {
    final over = now.subtract(const Duration(days: 1));
    final p = PlanProgress.of(plan(sessions: [session(over, 'a', gone: true), session(over.add(const Duration(hours: 1)), 'b', skipped: true)]), now);
    expect(p.pace, PlanPace.onTrack);
    expect(p.missed, 0);
    expect(p.sessionsAll, 1);
  });

  test('the next session is the first one to come that is not done; the time left counts the ones to come', () {
    final s1 = session(now.add(const Duration(days: 2)), 'b');
    final s2 = session(now.add(const Duration(days: 1)), 'a');
    final s3 = session(now.add(const Duration(days: 3)), 'a', credited: true);
    final p = PlanProgress.of(plan(sessions: [s1, s2, s3]), now);
    expect(p.next!.key, s2.key);
    expect(p.minutesLeft, 60);
    expect(p.sessionsDone, 1);
    expect(p.sessionsAll, 3);
    expect(p.daysLeft, 10);
  });

  test('the curve climbs with the sessions that were planned and with the ones that were done, and stops at today', () {
    final d0 = DateTime(2026, 11, 20, 16), d1 = DateTime(2026, 11, 21, 16), d2 = DateTime(2026, 11, 24, 16);
    final e = plan(sessions: [session(d0, 'a', credited: true), session(d1, 'b'), session(d2, 'a', kind: WorkKind.review)]);
    final c = PlanProgress.curve(e, now);
    expect(c.first.day, DateTime(2026, 11, 20));
    expect(c.last.day, DateTime(2026, 12, 2));
    expect(c.first.planned, closeTo(0.3, 1e-9));
    expect(c.first.actual, closeTo(0.3, 1e-9));
    // the day after: b was planned but not done
    expect(c[1].planned, closeTo(0.6, 1e-9));
    expect(c[1].actual, closeTo(0.3, 1e-9));
    // after today there is no actual, and the plan goes on climbing
    expect(c.firstWhere((p) => p.day == DateTime(2026, 11, 23)).actual, isNull);
    expect(c.last.planned, greaterThan(0.6));
    for (var i = 1; i < c.length; i++) {
      expect(c[i].planned, greaterThanOrEqualTo(c[i - 1].planned));
    }
  });

  test('pointing at a day to come gives the work still to do by then; at a day that is over, the work done since', () {
    final d0 = DateTime(2026, 11, 20, 16), d1 = DateTime(2026, 11, 22, 16), d2 = DateTime(2026, 11, 24, 16), d3 = DateTime(2026, 11, 26, 16);
    final e = plan(sessions: [session(d0, 'a', credited: true), session(d1, 'b'), session(d2, 'a', kind: WorkKind.review), session(d3, 'b', kind: WorkKind.review)]);
    final soon = workAround(e, now, DateTime(2026, 11, 24));
    expect(soon.ahead, isTrue);
    expect([for (final w in soon.work) (w.unit!.id, w.kind)], [('b', WorkKind.learn), ('a', WorkKind.review)]);
    final back = workAround(e, now, DateTime(2026, 11, 19));
    expect(back.ahead, isFalse);
    expect([for (final w in back.work) (w.unit!.id, w.kind)], [('a', WorkKind.learn)]);
    expect(workAround(e, now, DateTime(2026, 11, 20)).work, isEmpty);
  });

  test('parts are told apart by how far they are, and the focus is what has most left to do', () {
    expect(partStanding(null), PartStanding.notStarted);
    expect(partStanding((learned: 0.5, reviewed: 0.0)), PartStanding.learning);
    expect(partStanding((learned: 1.0, reviewed: 0.2)), PartStanding.toGoOver);
    expect(partStanding((learned: 1.0, reviewed: 1.0)), PartStanding.done);
    final e = plan(progress: {'a': (learned: 1.0, reviewed: 1.0), 'b': (learned: 0.5, reviewed: 0.0)});
    expect([for (final u in focusParts(e)) u.id], ['b']);
    expect([for (final u in focusParts(plan())) u.id].length, 2);
  });

  test('the time studied is what the reports say, or the length of the session without a report', () {
    final s1 = BookedSession(PlannedSession(now, 30, const [SessionItem(WorkKind.learn, unitId: 'a', minutes: 30)]), 'S', credited: true, report: const SessionReport(spent: 20, done: {0}));
    final s2 = session(now.add(const Duration(days: 1)), 'b', credited: true);
    expect(studiedMinutes(plan(sessions: [s1, s2])), 50);
  });
}
