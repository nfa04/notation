import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/review/study_planner.dart';
import 'package:notes/screens/review_view.dart';
import 'package:notes/screens/study_plan_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository notes;
  late CardRepository cards;
  late TaskRepository tasks;
  late StudyPlanner planner;
  late String noteId;
  final now = DateTime(2026, 6, 1, 8);

  Future<void> real(WidgetTester tester, [int times = 6]) async {
    for (var i = 0; i < times; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> open(WidgetTester tester, {int deck = 40, bool withCards = true}) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['settings', 'tasks', 'review_cards', 'notes']) {
        await db.delete(t);
      }
      notes = NoteRepository(db);
      cards = CardRepository(db);
      tasks = TaskRepository(db);
      noteId = await notes.createNote(title: 'Biology notes');
      if (withCards) await cards.addAll(noteId, [for (var i = 0; i < deck; i++) Flashcard('Question $i?', 'Answer $i')], now: now);
      planner = StudyPlanner(SettingsRepository(db), cards, tasks, now: () => now);
      await planner.load();
    });
    await tester.pumpWidget(MaterialApp(home: StudyPlanScreen(planner: planner, repository: notes, clock: () => now)));
    await real(tester, 2);
  }

  testWidgets('with no plan it says what a plan is; a new one asks for the exam, the cards and the minutes, and puts the sessions on the calendar', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('study-plans-empty')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('new-study-plan')));
    await tester.pumpAndSettle();
    await real(tester, 3);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('study-create'))).onPressed, isNull, reason: 'it needs a name');
    await tester.enterText(find.byKey(const ValueKey('study-name')), 'Biology');
    await tester.pump();

    // the cards of one note
    await tester.tap(find.byKey(const ValueKey('study-source')));
    await tester.pumpAndSettle();
    expect(find.text('Biology notes (40)'), findsOneWidget);
    await tester.tap(find.text('Biology notes (40)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('study-off-7')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('study-create')));
    await tester.pumpAndSettle();
    await real(tester, 8);

    final plan = planner.plans.single;
    expect((plan.name, plan.source, plan.minutes), ('Biology', noteId, 20));
    expect(plan.exam, DateTime(2026, 6, 15));
    expect(plan.daysOff, {7});
    expect(find.text('Biology'), findsOneWidget);
    expect(find.textContaining('14 days left: the exam is on 2026-06-15'), findsOneWidget);
    expect(find.byKey(ValueKey('study-today-${plan.id}')), findsOneWidget);
    expect(find.textContaining('Study Biology: '), findsOneWidget);
    final onCalendar = (await tester.runAsync(() => tasks.listTasks()))!;
    expect(onCalendar.length, plan.tasks.length);
    expect(onCalendar.where((t) => t.dueDate?.weekday == DateTime.sunday && t.dueDate != DateTime(2026, 6, 15)), isEmpty, reason: 'no session on the day off');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a plan that does not fit in the minutes says so, and deleting it takes its sessions off the calendar', (tester) async {
    await open(tester, deck: 400);
    late StudyPlanEntry plan;
    await tester.runAsync(() async => plan = await planner.create(name: 'Chemistry', exam: DateTime(2026, 6, 4), minutes: 10));
    await real(tester, 4);
    expect(find.byKey(ValueKey('study-warning-${plan.id}')), findsOneWidget);
    expect(find.textContaining('do not fit in the time'), findsOneWidget);
    expect((await tester.runAsync(() => tasks.listTasks()))!, isNotEmpty);

    await tester.tap(find.byKey(ValueKey('study-remove-${plan.id}')));
    await real(tester, 4);
    expect(find.byKey(const ValueKey('study-plans-empty')), findsOneWidget);
    expect((await tester.runAsync(() => tasks.listTasks()))!, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the review of the cards has the button to the plans, when plans are offered', (tester) async {
    await open(tester);
    await tester.pumpWidget(MaterialApp(home: ReviewScreen(cards: cards, planner: planner, repository: notes, clock: () => now)));
    await real(tester, 3);
    expect(find.byKey(const ValueKey('study-plans')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('study-plans')));
    await tester.pumpAndSettle();
    expect(find.text('Plan for an exam'), findsWidgets);
    expect(find.byKey(const ValueKey('new-study-plan')), findsOneWidget);
    await tester.pumpWidget(MaterialApp(home: ReviewScreen(cards: cards, clock: () => now)));
    await real(tester, 2);
    expect(find.byKey(const ValueKey('study-plans')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
