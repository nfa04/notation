import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/review/study_plan.dart';
import 'package:notes/review/study_calendar.dart';
import 'package:notes/review/study_material.dart';
import 'package:notes/review/study_planner.dart';
import 'package:notes/review/study_schedule.dart';
import 'package:notes/sync/caldav_remote.dart';

import 'fake_study_calendar.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final monday = DateTime(2026, 6, 1);
  DateTime day(int n) => DateTime(2026, 6, n);

  group('the plan', () {
    test('new cards are spread over the first part of the time, the last days are for going over them, the exam day is short', () {
      final plan = planStudy(today: monday, exam: day(11), stats: const CardStats(unseen: 70), minutesPerDay: 20);
      expect(plan.capacity, 60);
      final sessions = plan.sessions;
      expect(sessions.last.day, day(11));
      expect(sessions.last.examDay, isTrue);
      expect(sessions.last.newCards, 0);
      expect(sessions.where((s) => !s.examDay).map((s) => s.day), [for (var i = 1; i <= 10; i++) day(i)].where(sessions.map((s) => s.day).contains), reason: 'in order');
      final withNew = sessions.where((s) => s.newCards > 0).toList();
      expect(withNew.fold<int>(0, (n, s) => n + s.newCards), 70, reason: 'all of them are seen once');
      expect(withNew.length, 7, reason: 'the first seven of the ten days: 70 percent');
      expect(withNew.every((s) => s.newCards == 10), isTrue);
      expect(plan.unplanned, 0);
      // from the day after the first new cards there is something to go over, and it grows with what has been seen
      final reviews = [for (final s in sessions.where((s) => !s.examDay)) s.reviews + s.weak];
      expect(reviews.first, 0, reason: 'nothing has been seen on the first day');
      expect(reviews[3], greaterThan(reviews[1]));
    });

    test('the cards that are due come first, and no day holds more than the minutes allow', () {
      final plan = planStudy(today: monday, exam: day(8), stats: const CardStats(unseen: 20, seen: 100, due: 45, weak: 6), minutesPerDay: 15);
      expect(plan.capacity, 45);
      expect(plan.sessions.first.reviews, 45 - plan.sessions.first.newCards);
      for (final s in plan.sessions.where((s) => !s.examDay)) {
        expect(s.cards, lessThanOrEqualTo(plan.capacity), reason: '${s.day}');
        expect(s.minutes, lessThanOrEqualTo(15 + 1));
      }
    });

    test('the weak spots get a share of the last three days, and the exam day is about them', () {
      final plan = planStudy(today: monday, exam: day(14), stats: const CardStats(unseen: 0, seen: 80, due: 10, weak: 12), minutesPerDay: 20);
      final study = plan.sessions.where((s) => !s.examDay).toList();
      expect(study.reversed.take(3).every((s) => s.weak == 12), isTrue);
      expect(study.reversed.skip(3).every((s) => s.weak == 0), isTrue);
      final exam = plan.sessions.last;
      expect((exam.examDay, exam.weak, exam.newCards), (true, 12, 0));
    });

    test('too little time: what cannot be fitted is said', () {
      final plan = planStudy(today: monday, exam: day(4), stats: const CardStats(unseen: 400), minutesPerDay: 10);
      expect(plan.capacity, 30);
      expect(plan.unplanned, greaterThan(300));
      expect(plan.sessions.where((s) => s.newCards > 0).every((s) => s.newCards <= 18), isTrue, reason: 'a part of the day is for going over what was learned');
    });

    test('days off have no session, the exam day always has one; exam today, tomorrow, in the past, or no cards', () {
      final plan = planStudy(today: monday, exam: day(8), stats: const CardStats(unseen: 14), daysOff: {6, 7});
      expect(plan.sessions.every((s) => s.examDay || ![6, 7].contains(s.day.weekday)), isTrue);
      expect(plan.sessions.last.day, day(8));
      expect(planStudy(today: monday, exam: monday, stats: const CardStats(seen: 20, weak: 4)).sessions.single.examDay, isTrue);
      final tomorrow = planStudy(today: monday, exam: day(2), stats: const CardStats(unseen: 10, seen: 10));
      expect(tomorrow.sessions.map((s) => s.day), [monday, day(2)]);
      expect(planStudy(today: day(5), exam: day(2), stats: const CardStats(unseen: 10)).sessions, isEmpty);
      expect(planStudy(today: monday, exam: day(9), stats: const CardStats()).sessions, isEmpty);
    });

  });

  group('a plan on the calendar', () {
    setUpAll(AppDatabase.initFfi);
    late Database db;
    late CardRepository cards;
    late TaskRepository tasks;
    late FakeStudyCalendar calendar;
    late StudyPlanner planner;
    var now = DateTime(2026, 6, 1, 8);
    final words = List.filled(1200, 'word').join(' '); // 12 minutes a section

    NoteShape shape(String id) => NoteShape(
          noteId: id,
          title: 'Biology',
          pdfPages: 40,
          pdfOutline: const [(title: 'Cells', level: 1, page: 0), (title: 'Genetics', level: 1, page: 10), (title: 'Evolution', level: 1, page: 25)],
          documentText: '# Summary\n$words',
        );

    setUp(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['settings', 'tasks', 'review_cards']) {
        await db.delete(t);
      }
      cards = CardRepository(db);
      tasks = TaskRepository(db);
      calendar = FakeStudyCalendar();
      now = DateTime(2026, 6, 1, 8);
      planner = StudyPlanner(SettingsRepository(db), cards, tasks, calendar: calendar, readNote: (id) async => id == 'gone' ? null : shape(id), now: () => now);
      await planner.load();
    });
    tearDown(() => planner.dispose());

    Future<StudyPlanEntry> biology({CalendarTarget target = const CalendarTarget.makeAt(CalendarPlace.phone), DateTime? exam}) async {
      final units = await planner.unitsOf('n1');
      return planner.draft(name: 'Biology', exam: exam ?? day(12)).copyWith(units: units, cardSources: () => const {}, target: target);
    }

    test('the units of a note come from its PDF chapters and its document; a note that is gone has none', () async {
      final units = await planner.unitsOf('n1');
      expect([for (final u in units) u.title], ['Cells', 'Genetics', 'Evolution', 'Summary']);
      expect(await planner.unitsOf('gone'), isEmpty);
    });

    test('a proposal writes nothing; approving it makes the Study calendar and puts each session there and in the to-dos', () async {
      final p = await planner.propose(await biology());
      expect(p.sessions, isNotEmpty);
      expect(p.sessions.every((s) => s.change == SessionChange.added), isTrue);
      expect(await tasks.listTasks(), isEmpty);
      expect(calendar.written, isEmpty);
      expect(planner.plans, isEmpty, reason: 'not kept before it is approved');

      final e = await planner.approve(p);
      expect(calendar.made, [CalendarPlace.phone]);
      expect(e.target, const CalendarTarget.calendar('phone:study'));
      final list = await tasks.listTasks();
      expect(list, hasLength(p.sessions.length));
      expect(calendar.written, hasLength(p.sessions.length));
      final first = e.sessions.first;
      final event = calendar.written[first.eventId]!;
      expect(event.$1, 'phone:study');
      expect((event.$2.start, event.$2.end, event.$2.allDay), (first.session.start, first.session.end, false));
      expect(event.$2.title, startsWith('Biology: Cells'));
      expect(event.$2.description, contains('Learn: Cells'));
      expect(list.firstWhere((t) => t.id == first.taskId).title, '16:00 ${event.$2.title}');
      expect(list.every((t) => planner.ownsTask(t.id)), isTrue, reason: 'the mirror leaves them alone');
      expect(planner.problem, isNull);

      // a second plan uses the calendar that is there, and not the times of the first
      final second = await planner.approve(await planner.propose(planner.draft(name: 'Physics', exam: day(12)).copyWith(units: await planner.unitsOf('n2'), cardSources: () => const {}, target: const CalendarTarget.makeAt(CalendarPlace.phone))));
      expect(calendar.made, hasLength(1));
      final taken = {for (final s in e.sessions) s.key};
      expect(second.sessions.where((s) => taken.contains(s.key)), isEmpty);
    });

    test('proposing an approved plan again changes nothing; its own events are not busy times, the events of others are', () async {
      calendar.others.add(DayEvent(title: 'Football', start: DateTime(2026, 6, 1, 16), end: DateTime(2026, 6, 1, 18), allDay: false, calendarName: 'Private', calendarKey: 'phone:p'));
      final e = await planner.approve(await planner.propose(await biology()));
      expect(e.sessions.where((s) => s.session.start.day == 1 && s.session.start.isBefore(DateTime(2026, 6, 1, 18, 10))), isEmpty);
      final again = await planner.propose(e);
      expect(again.hasChanges, isFalse);
      expect(again.events.map((ev) => ev.title), ['Football']);
      final written = calendar.written.length;
      await planner.approve(again);
      expect(calendar.written.length, written, reason: 'nothing is written twice');
      expect((await tasks.listTasks()).length, written);
    });

    test('a ticked-off session counts; a missed one is noticed, and the plan made again moves its work on once approved', () async {
      final e = await planner.approve(await planner.propose(await biology()));
      final first = e.sessions[0], second = e.sessions[1];
      await tasks.setDone(first.taskId!, true);
      now = second.session.end.add(const Duration(minutes: 5));
      await planner.refresh();
      final kept = planner.plans.single;
      expect(kept.progress['n1#0']!.learned, greaterThan(0));
      expect(kept.sessions.first.credited, isTrue);
      expect(planner.attentionOf(e.id).missed, 1);
      expect(planner.attentionOf(e.id).any, isTrue);

      final p = await planner.propose(kept);
      expect(p.hasChanges, isTrue);
      // the work of the missed session comes again
      final missedUnit = second.session.items.firstWhere((i) => i.kind == WorkKind.learn).unitId!;
      final learnt = [for (final s in p.sessions) for (final i in s.session.items) if (i.unitId == missedUnit && i.kind == WorkKind.learn) i];
      expect(learnt.first.from, closeTo(kept.progress[missedUnit]?.learned ?? 0, 1e-6));
      expect(learnt.first.from, lessThanOrEqualTo(second.session.items.firstWhere((i) => i.kind == WorkKind.learn).from + 1e-6));
      final after = await planner.approve(p);
      expect(after.sessions.firstWhere((s) => s.key == second.key).skipped, isTrue);
      expect(after.sessions.firstWhere((s) => s.key == first.key).taskId, first.taskId);
      expect((await tasks.listTasks()).any((t) => t.id == first.taskId), isTrue, reason: 'what was done stays');
      await planner.refresh();
      expect(planner.attentionOf(e.id).missed, 0, reason: 'a missed session is said once');
      // every booked event is one of the plan's sessions
      expect(calendar.written.keys.toSet(), {for (final s in after.sessions) if (s.eventId != null) s.eventId});
    });

    test('a new event at the time of a session, or a deleted to-do, is noticed (nothing is changed before it is approved)', () async {
      final e = await planner.approve(await planner.propose(await biology()));
      final s = e.sessions[2];
      // (at exactly the time of the session, in another calendar: not taken for the session's own event)
      calendar.others.add(DayEvent(title: 'Dentist', start: s.session.start, end: s.session.end, allDay: false, calendarName: 'Private', calendarKey: 'phone:p'));
      await tasks.deleteTask(e.sessions[3].taskId!);
      await planner.refresh();
      expect(planner.attentionOf(e.id).clashes, 1);
      expect(planner.attentionOf(e.id).dropped, 1);
      expect(calendar.written.containsKey(s.eventId), isTrue);
      final p = await planner.propose(planner.plans.single);
      expect(p.removed.map((r) => r.key).toList()..addAll(p.sessions.where((x) => x.change != SessionChange.same).map((x) => x.session.key)), contains(s.key));
      await planner.approve(p);
      expect(calendar.written.containsKey(s.eventId), isFalse);
      await planner.refresh();
      expect(planner.attentionOf(e.id).any, isFalse);
    });

    test('taking a plan away takes its sessions to come off the calendar and the to-dos; what was done stays', () async {
      final e = await planner.approve(await planner.propose(await biology()));
      await tasks.setDone(e.sessions.first.taskId!, true);
      await planner.remove(e.id);
      expect(planner.plans, isEmpty);
      expect(calendar.written.keys, [e.sessions.first.eventId]);
      expect((await tasks.listTasks()).map((t) => t.id), [e.sessions.first.taskId]);
    });

    test('a calendar that cannot be written: the to-dos are made, the problem is said, and the next approval writes the events', () async {
      calendar.failWrites = true;
      final e = await planner.approve(await planner.propose(await biology(target: const CalendarTarget.calendar('phone:p'))));
      expect(planner.problem, contains('offline'));
      expect((await tasks.listTasks()).length, e.sessions.length);
      expect(e.sessions.every((s) => s.eventId == null), isTrue);
      calendar.failWrites = false;
      await planner.approve(await planner.propose(e));
      expect(calendar.written.length, e.sessions.length);
      expect((await tasks.listTasks()).length, e.sessions.length, reason: 'no to-do twice');
      expect(planner.problem, isNull);
    });

    test('to-dos only: no calendar is touched', () async {
      final e = await planner.approve(await planner.propose(await biology(target: const CalendarTarget.none())));
      expect(calendar.written, isEmpty);
      expect(calendar.made, isEmpty);
      expect((await tasks.listTasks()).length, e.sessions.length);
    });

    test('flashcards: the cards of the plan get their minutes in the first session of a day', () async {
      await cards.addAll('n1', [for (var i = 0; i < 30; i++) Flashcard('Question $i?', 'Answer $i')], now: now);
      final draft = (await biology()).copyWith(cardSources: () => {'n1'});
      final p = await planner.propose(draft);
      expect(p.sessions.first.session.items.first.kind, WorkKind.cards);
      final none = await planner.propose(draft.copyWith(cardSources: () => const {}));
      expect(none.sessions.expand((s) => s.session.items).where((i) => i.kind == WorkKind.cards), isEmpty);
    });

    test('a plan from before sessions had times: kept with its to-dos, wants to be booked, and its to-dos go once it is', () async {
      final old = await tasks.createTask('Study Heaps: 10 new', dueDate: day(2), auto: true);
      final done = await tasks.createTask('Study Heaps: 5 new', dueDate: day(1), auto: true);
      await tasks.setDone(done, true);
      await SettingsRepository(db).set('study_plans', '[{"id":"a","name":"Heaps","source":"n1","exam":"2026-06-10","minutes":30,"off":[7],"tasks":{"2026-06-01":"$done","2026-06-02":"$old"}}]');
      await planner.load();
      final e = planner.plans.single;
      expect((e.maxPerDay, e.legacyTasks.length), (30, 2));
      expect(e.cardSources, {'n1'});
      expect(e.daysOff, {7});
      expect(planner.ownsTask(old), isTrue);
      await planner.refresh();
      expect(planner.attentionOf('a').unbooked, isTrue);
      await cards.addAll('n1', [for (var i = 0; i < 10; i++) Flashcard('Q $i?', 'A $i')], now: now);
      await planner.approve(await planner.propose(e.copyWith(target: const CalendarTarget.none())));
      final ids = (await tasks.listTasks()).map((t) => t.id).toSet();
      expect(ids.contains(old), isFalse);
      expect(ids.contains(done), isTrue);
      expect(planner.plans.single.legacyTasks, isEmpty);
    });

    test('a plan is kept, and dropped once the exam is over', () async {
      await planner.approve(await planner.propose(await biology(exam: day(3))));
      final again = StudyPlanner(SettingsRepository(db), cards, tasks, calendar: calendar, now: () => now);
      await again.load();
      expect(again.plans.single.name, 'Biology');
      expect(again.plans.single.sessions, isNotEmpty);
      expect(again.plans.single.target, const CalendarTarget.calendar('phone:study'));
      now = DateTime(2026, 6, 4, 8);
      await again.refresh();
      expect(again.plans, isEmpty);
      again.dispose();
    });
  });

  test('a plan is read back from what was kept, and a damaged one is left out', () {
    expect(StudyPlanEntry.fromJson({'id': 'x', 'exam': 'not a day'}), isNull);
    expect(StudyPlanEntry.fromJson('nope'), isNull);
    final session = BookedSession(PlannedSession(DateTime(2026, 6, 1, 16), 45, const [SessionItem(WorkKind.learn, unitId: 'u', to: 0.5, minutes: 40)]), 'B: x',
        taskId: 't', eventId: 'e', eventTarget: 'phone:s', credited: true);
    final e = StudyPlanEntry.fromJson(StudyPlanEntry(
      id: 'a',
      name: 'n',
      exam: DateTime(2026, 6, 6),
      examTime: 9 * 60,
      daysOff: const {7},
      units: const [StudyUnit(id: 'u', noteId: 'n', title: 'Cells', minutes: 20)],
      cardSources: const {'n'},
      windowStart: 8 * 60,
      windowEnd: 12 * 60,
      maxPerDay: 90,
      sessionLength: 25,
      target: const CalendarTarget.calendar('phone:s'),
      progress: const {'u': (learned: 0.5, reviewed: 0.0)},
      sessions: [session],
      blocked: [(start: DateTime(2026, 6, 2, 9), end: DateTime(2026, 6, 2, 10))],
    ).toJson())!;
    expect((e.name, e.exam, e.examTime), ('n', DateTime(2026, 6, 6), 540));
    expect(e.daysOff, {7});
    expect(e.cardSources, {'n'});
    expect((e.windowStart, e.windowEnd, e.maxPerDay, e.sessionLength, e.target), (480, 720, 90, 25, const CalendarTarget.calendar('phone:s')));
    expect(e.units.single.title, 'Cells');
    expect(e.progress['u']!.learned, 0.5);
    expect(e.learned, 0.5);
    final back = e.sessions.single;
    expect((back.key, back.title, back.taskId, back.eventId, back.eventTarget, back.credited), ('2026-06-01T1600', 'B: x', 't', 'e', 'phone:s', true));
    expect(back.session.items, session.session.items);
    expect(e.blocked.single.start, DateTime(2026, 6, 2, 9));
    expect(StudyPlanEntry.fromJson({'id': 'x', 'exam': '2026-06-06', 'v': 2, 'cards': []})!.cardSources, isEmpty);
  });
}
