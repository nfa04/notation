import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/ai/spaced_repetition.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/review/study_plan.dart';
import 'package:notes/review/study_planner.dart';
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
      expect(sessionTitle('Biology', exam), startsWith('Exam day: Biology'));
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

    test('the title of a session says what to do and how long it takes', () {
      expect(sessionTitle('Heaps', StudySession(DateTime(2026, 6, 1), newCards: 10, reviews: 12, weak: 3, minutes: 12)),
          'Study Heaps: 10 new, 15 to go over (3 weak) (about 12 min)');
      expect(sessionTitle('Heaps', StudySession(DateTime(2026, 6, 1), reviews: 8, minutes: 5)), 'Study Heaps: 8 to go over (about 5 min)');
    });
  });

  group('on the calendar', () {
    setUpAll(AppDatabase.initFfi);
    late Database db;
    late CardRepository cards;
    late TaskRepository tasks;
    late StudyPlanner planner;
    var now = DateTime(2026, 6, 1, 8);

    setUp(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['settings', 'tasks', 'review_cards']) {
        await db.delete(t);
      }
      cards = CardRepository(db);
      tasks = TaskRepository(db);
      now = DateTime(2026, 6, 1, 8);
      planner = StudyPlanner(SettingsRepository(db), cards, tasks, now: () => now);
      await planner.load();
    });
    tearDown(() => planner.dispose());

    Future<void> deck(int n, {String source = 'notes'}) => cards.addAll(source, [for (var i = 0; i < n; i++) Flashcard('Question $i?', 'Answer $i')], now: now);

    test('a plan puts a task on each day with its session; making it again changes nothing that is right', () async {
      await deck(30);
      final entry = await planner.create(name: 'Heaps', exam: day(6), minutes: 20);
      final list = await tasks.listTasks();
      expect(list.length, entry.tasks.length);
      expect(list.every((t) => t.auto), isTrue);
      expect(list.map((t) => t.dueDate).toSet(), {for (var d = 1; d <= 6; d++) day(d)}.where((d) => list.any((t) => t.dueDate == d)).toSet());
      expect(list.firstWhere((t) => t.dueDate == day(6)).title, startsWith('Exam day: Heaps'));
      expect(list.firstWhere((t) => t.dueDate == day(1)).title, matches(RegExp(r'^Study Heaps: \d+ new')));
      final before = [for (final t in list) t.title];
      await planner.refresh();
      expect([for (final t in await tasks.listTasks()) t.title], before);
      expect((await tasks.listTasks()).length, list.length, reason: 'no task twice');
    });

    test('what was got right changes the days that are left: cards that stuck are not asked as often, forgotten ones become weak spots', () async {
      await deck(24);
      await planner.create(name: 'Heaps', exam: day(8), minutes: 20);
      String titleOn(int d, List tasksNow) => (tasksNow.cast().firstWhere((t) => t.dueDate == day(d)) as dynamic).title as String;
      var list = await tasks.listTasks();
      final planned = titleOn(3, list);

      // a day later, every card was answered, and a few were forgotten three times
      now = DateTime(2026, 6, 2, 8);
      final all = await cards.due(now: DateTime(2030), source: 'notes');
      for (final c in all) {
        await cards.review(c, Recall.good, now: now);
      }
      for (final c in all.take(4)) {
        for (var i = 0; i < 3; i++) {
          final fresh = (await cards.due(now: DateTime(2030), source: 'notes')).firstWhere((x) => x.id == c.id);
          await cards.review(fresh, Recall.good, now: now);
          final again = (await cards.due(now: DateTime(2030), source: 'notes')).firstWhere((x) => x.id == c.id);
          await cards.review(again, Recall.again, now: now);
        }
      }
      expect((await cards.stats(source: 'notes', now: now)).weak, 4);
      await planner.refresh();
      list = await tasks.listTasks();
      expect(titleOn(3, list), isNot(planned));
      expect(titleOn(7, list), contains('4 weak'), reason: 'near the exam the weak ones are asked');
      expect(titleOn(8, list), startsWith('Exam day'));
      expect(list.where((t) => t.dueDate == day(1)), hasLength(1), reason: 'the day that was has its task, which is left as it was');
    });

    test('a session that was done stays, one that is not needed any more goes, and so does the plan when it is taken away', () async {
      await deck(10);
      final entry = await planner.create(name: 'Heaps', exam: day(6), minutes: 20);
      final first = (await tasks.listTasks()).firstWhere((t) => t.dueDate == day(1));
      await tasks.setDone(first.id, true);
      // all cards seen and known: fewer days need a session
      now = DateTime(2026, 6, 2, 8);
      await planner.remove(entry.id);
      final left = await tasks.listTasks();
      expect(left.map((t) => t.id), [first.id], reason: 'only the one that was done');
      expect(planner.plans, isEmpty);
    });

    test('a plan is kept, and dropped once the exam is over', () async {
      await deck(10);
      await planner.create(name: 'Heaps', exam: day(3), minutes: 20);
      final again = StudyPlanner(SettingsRepository(db), cards, tasks, now: () => now);
      await again.load();
      expect(again.plans.single.name, 'Heaps');
      expect(again.plans.single.tasks, isNotEmpty);
      now = DateTime(2026, 6, 4, 8);
      await again.refresh();
      expect(again.plans, isEmpty);
      again.dispose();
    });

    test('a plan for the cards of one note ignores the others', () async {
      await deck(10, source: 'n1');
      await deck(50, source: 'n2');
      expect((await cards.stats(source: 'n1', now: now)).total, 10);
      expect((await cards.stats(now: now)).total, 60);
      expect(await cards.sourceCounts(), {'n2': 50, 'n1': 10});
      final entry = await planner.create(name: 'One note', source: 'n1', exam: day(5));
      final plan = await planner.planOf(entry);
      expect(plan.sessions.fold<int>(0, (n, s) => n + s.newCards), 10);
    });

    test('cards answered start a new plan a moment later (once started)', () async {
      await deck(10);
      final entry = await planner.create(name: 'Heaps', exam: day(6), minutes: 20);
      planner.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(planner.plans.single.id, entry.id);
    });
  });

  test('a plan is read back from what was kept, and a damaged one is left out', () {
    expect(StudyPlanEntry.fromJson({'id': 'x', 'exam': 'not a day'}), isNull);
    expect(StudyPlanEntry.fromJson('nope'), isNull);
    final e = StudyPlanEntry.fromJson(StudyPlanEntry(id: 'a', name: 'n', exam: DateTime(2026, 6, 6), daysOff: const {7}, tasks: const {'2026-06-01': 't'}).toJson())!;
    expect((e.name, e.exam), ('n', DateTime(2026, 6, 6)));
    expect(e.daysOff, {7});
    expect(e.tasks, {'2026-06-01': 't'});
  });
}
