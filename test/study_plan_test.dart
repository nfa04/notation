import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:notes/ai/flashcards.dart';
import 'package:notes/algebra/mistake_card.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/review/study_plan.dart';
import 'package:notes/review/study_calendar.dart';
import 'package:notes/review/study_material.dart';
import 'package:notes/graph/study.dart';
import 'package:notes/review/study_planner.dart';
import 'package:notes/review/study_practice.dart';
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

    test('a session studied with its screen: the clock leaves out pauses, the ticks are kept, and only what was done counts', () async {
      final e = await planner.approve(await planner.propose(await biology()));
      final s = e.sessions.firstWhere((s) => s.session.items.where((i) => i.kind == WorkKind.learn).length >= 2);
      final first = s.session.items.indexWhere((i) => i.kind == WorkKind.learn);
      final second = s.session.items.indexWhere((i) => i.kind == WorkKind.learn, first + 1);
      now = s.session.start;
      await planner.begin(e.id, s.key);
      now = now.add(const Duration(minutes: 10));
      await planner.pause(true);
      now = now.add(const Duration(minutes: 30));
      expect(planner.running!.elapsed(now), const Duration(minutes: 10), reason: 'paused');
      await planner.pause(false);
      now = now.add(const Duration(minutes: 20));
      await planner.check(first, true);
      expect(planner.running!.elapsed(now), const Duration(minutes: 30));
      expect(planner.current()!.session.key, s.key, reason: 'the session being studied is the one offered');

      // closing the app keeps the clock and the ticks
      final reopened = StudyPlanner(SettingsRepository(db), cards, tasks, calendar: calendar, now: () => now);
      await reopened.load();
      expect((reopened.running!.key, reopened.running!.elapsed(now)), (s.key, const Duration(minutes: 30)));
      expect(reopened.running!.checked, {first});
      reopened.dispose();

      final a = s.session.items[first], b = s.session.items[second];
      final before = planner.plans.single.unit(a.unitId!)!.difficulty;
      final changed = await planner.finish(e.id, s.key, SessionReport(spent: 30, done: {first}, feeling: SessionFeeling.hard));
      final kept = planner.plans.single;
      final booked = kept.sessions.firstWhere((x) => x.key == s.key);
      expect(booked.report!.done, {first});
      expect(booked.credited, isTrue);
      expect((await tasks.listTasks()).firstWhere((t) => t.id == s.taskId).done, isTrue, reason: 'its to-do is ticked off');
      expect(planner.running, isNull);
      // (the sessions before it were not done: only its own share counts)
      expect(kept.progress[a.unitId]!.learned, closeTo(a.to - a.from, 1e-6), reason: 'what was done counts');
      expect(kept.progress[b.unitId]?.learned ?? 0, 0, reason: 'what was not done does not');
      expect(changed.map((u) => u.id), [a.unitId]);
      expect(kept.unit(a.unitId!)!.difficulty.index, before.index + 1, reason: 'it felt hard');
      expect(kept.unit(b.unitId!)!.difficulty, Difficulty.medium, reason: 'not done: not judged');
      expect(planner.attentionOf(e.id).unfinished, 1);
      expect(planner.speedOf(kept), closeTo((30 + 60) / (a.minutes + 60), 0.01));
      expect(planner.startOfTask(s.taskId!), isNull, reason: 'no reminder for a session that was studied');

      // made again: the work left comes again, and the session is not reported again
      final p = await planner.propose(kept);
      expect([for (final x in p.sessions) for (final i in x.session.items) if (i.unitId == b.unitId && i.kind == WorkKind.learn) i.from].first,
          closeTo(kept.progress[b.unitId]?.learned ?? 0, 1e-6));
      await planner.approve(p);
      await planner.refresh();
      expect(planner.attentionOf(e.id).unfinished, 0);
    });

    test('the pace of the sessions makes the rest take longer, and is said until the plan is made with it', () async {
      final e = await planner.approve(await planner.propose(await biology()));
      final s = e.sessions.first;
      now = s.session.start;
      final needed = (await planner.propose(e)).schedule.needed;
      final planned = s.session.items.fold<int>(0, (n, i) => n + i.minutes);
      now = s.session.end;
      await planner.finish(e.id, s.key, SessionReport(spent: planned * 3, done: {for (var i = 0; i < s.session.items.length; i++) i}));
      final kept = planner.plans.single;
      expect(planner.speedOf(kept), closeTo(1.8, 1e-9), reason: 'three times as long, but within the limit');
      expect(planner.attentionOf(e.id).pace, closeTo(1.8, 1e-9));
      final p = await planner.propose(kept);
      expect(p.entry.speed, closeTo(1.8, 1e-9));
      expect(p.schedule.needed, greaterThan(needed * 1.3), reason: 'the work left, at the pace measured');
      await planner.approve(p);
      await planner.refresh();
      expect(planner.attentionOf(e.id).pace, isNull, reason: 'the plan is made with it now');
      expect(planner.plans.single.speed, closeTo(1.8, 1e-9));
    });

    test('today\'s session is offered and has its reminder at its start; another day\'s is not offered', () async {
      final e = await planner.approve(await planner.propose(await biology()));
      final first = e.sessions.first;
      final day = first.session.start.day;
      now = DateTime(2026, 6, day, 8);
      expect(planner.current()!.session.key, first.key);
      expect(planner.startOfTask(first.taskId!), first.session.start);
      expect(planner.startOfTask('not a session'), isNull);
      expect(planner.findByTask(first.taskId!)!.session.key, first.key);
      // after the day's sessions (and an hour more) nothing is offered until the next day
      final lastToday = e.sessions.lastWhere((s) => s.session.start.day == day);
      now = lastToday.session.end.add(const Duration(hours: 2));
      expect(planner.current(), isNull);
      final next = e.sessions.firstWhere((s) => s.session.start.day > day).session.start;
      now = DateTime(next.year, next.month, next.day, 8);
      expect(planner.current()!.session.session.start, next);
    });

    test('the maths mistakes kept of a part and a quiz on its facts are done right after its going over, as time of their own', () async {
      final plain = await planner.propose(await biology());
      await cards.addAll('n1', [
        Flashcard('${mistakeFront}a+b=ab', 'Not a product.', page: 3),
        Flashcard('${mistakeFront}x^2=2x', 'The power was lost.', page: 12),
        const Flashcard('What is a cell?', 'A unit of life.', page: 2),
      ]);
      final source = _Facts([for (var i = 0; i < 3; i++) (noteId: 'n1', page: 1 + i, fact: StudyFact('Cell $i', 'Cells do thing $i.'))]);
      planner.facts = source;
      final p = await planner.propose(await biology());
      final units = {for (final u in p.entry.units) u.title: u};
      final cells = units['Cells']!, genetics = units['Genetics']!;

      // right after the part's going over (in the order of the work), mistakes first, never cut in two; extra time, the going over keeps its own
      final flat = [for (final x in p.sessions) ...x.session.items];
      int at(WorkKind kind, StudyUnit u) => flat.indexWhere((i) => i.kind == kind && i.unitId == u.id);
      final lastReview = flat.lastIndexWhere((i) => i.kind == WorkKind.review && i.unitId == cells.id);
      expect(flat[lastReview].to, closeTo(1, 1e-6));
      expect((at(WorkKind.mistakes, cells), at(WorkKind.quiz, cells)), (lastReview + 1, lastReview + 2));
      expect([for (final i in flat) if (i.unitId == cells.id && i.kind.index >= WorkKind.mistakes.index) (i.kind, i.minutes)], [(WorkKind.mistakes, 5), (WorkKind.quiz, 10)]);
      int minutesOf(StudyProposal x, WorkKind kind) => [for (final y in x.sessions) ...y.session.items].where((i) => i.kind == kind).fold(0, (n, i) => n + i.minutes);
      expect(minutesOf(p, WorkKind.review), closeTo(minutesOf(plain, WorkKind.review), 3));
      expect(minutesOf(p, WorkKind.mistakes), 5 + 5);
      expect(at(WorkKind.mistakes, genetics), greaterThan(flat.lastIndexWhere((i) => i.kind == WorkKind.review && i.unitId == genetics.id)));
      expect(at(WorkKind.quiz, genetics), -1, reason: 'no facts of its pages');
      expect(at(WorkKind.mistakes, units['Evolution']!), -1);
      expect(itemText(flat[lastReview + 1], cells), 'Do the lines you got wrong again: Cells');

      expect([for (final c in await planner.mistakesOf(cells)) mistakeLineOf(c.card.front)], ['a+b=ab']);
      expect(await planner.factsOf(cells), hasLength(3));

      // without a model there is no quiz
      source.ready = false;
      final again = await planner.propose(await biology());
      expect([for (final s in again.sessions) ...s.session.items.where((i) => i.kind == WorkKind.quiz)], isEmpty);
      expect(await planner.factsOf(cells), isEmpty);
    });

    test('a session moved in the calendar app goes with it, to-do too, and stays there; one deleted there is said and its time kept free', () async {
      final e = await planner.approve(await planner.propose(await biology()));
      final a = e.sessions[2], b = e.sessions[4];
      final moved = DateTime(a.session.start.year, a.session.start.month, a.session.start.day, 7);
      final ev = calendar.written[a.eventId]!;
      calendar.written[a.eventId!] = (ev.$1, NewEvent(title: ev.$2.title, start: moved, end: moved.add(const Duration(minutes: 30)), description: ev.$2.description));
      calendar.written.remove(b.eventId);

      // a calendar that cannot be read says nothing
      calendar.unreadable = true;
      await planner.refresh(lookAtCalendar: true);
      expect(planner.plans.single.sessions.where((s) => s.gone || s.moved), isEmpty);
      expect(planner.attentionOf(e.id).any, isFalse);

      calendar.unreadable = false;
      await planner.refresh(lookAtCalendar: true);
      var plan = planner.plans.single;
      final m = plan.sessions.firstWhere((s) => s.taskId == a.taskId);
      expect((m.session.start, m.session.minutes, m.moved, m.gone), (moved, 30, true, false));
      expect(m.session.items, a.session.items);
      final task = (await tasks.listTasks()).firstWhere((t) => t.id == a.taskId);
      expect((task.title, task.dueDate), ('07:00 ${a.title}', DateTime(moved.year, moved.month, moved.day)));
      expect(planner.startOfTask(a.taskId!), moved);
      final g = plan.sessions.firstWhere((s) => s.taskId == b.taskId);
      expect(g.gone, isTrue);
      expect(planner.startOfTask(b.taskId!), isNull, reason: 'no reminder for it');
      final attention = planner.attentionOf(e.id);
      expect((attention.removed, attention.clashes, attention.any), (1, 0, true));
      expect(plan.blocked, contains((start: b.session.start, end: b.session.end)));

      // made again: the moved one stays with its work, nothing is put at the deleted time, and that to-do goes once approved
      final p = await planner.propose(plan);
      expect(p.removed.map((r) => r.taskId), isNot(contains(a.taskId)));
      expect(p.removed.map((r) => r.taskId), contains(b.taskId));
      expect(p.sessions.where((s) => s.session.start.isBefore(b.session.end) && s.session.end.isAfter(b.session.start)), isEmpty);
      bool sameWork(SessionItem x, SessionItem y) => x.kind == y.kind && x.unitId == y.unitId && (x.from - y.from).abs() < 1e-6;
      for (final item in a.session.items.where((i) => i.kind == WorkKind.learn)) {
        expect(p.sessions.where((s) => s.session.items.any((i) => sameWork(i, item))), isEmpty, reason: 'its work is not planned twice');
      }
      await planner.approve(p);
      plan = planner.plans.single;
      expect(plan.sessions.where((s) => s.taskId == a.taskId).single.session.start, moved);
      expect(plan.sessions.where((s) => s.taskId == a.taskId).single.skipped, isFalse);
      final left = await tasks.listTasks();
      expect(left.any((t) => t.id == b.taskId), isFalse);
      expect(left.any((t) => t.id == a.taskId), isTrue);
      await planner.refresh(lookAtCalendar: true);
      expect(planner.attentionOf(e.id).any, isFalse);
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

/// Facts of graphs, and whether a model could make a quiz of them.
class _Facts implements StudyFactSource {
  final List<FactSpot> spots;
  bool ready = true;
  _Facts(this.spots);

  @override
  bool get canQuiz => ready;

  @override
  Future<List<FactSpot>> facts() async => spots;

  @override
  Future<void> quiz(BuildContext context, String title, List<StudyFact> facts, {CardRepository? cards}) async {}
}
