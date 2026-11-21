import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/review/study_calendar.dart';
import 'package:notes/review/study_material.dart';
import 'package:notes/review/study_planner.dart';
import 'package:notes/screens/review_view.dart';
import 'package:notes/screens/study_plan_screen.dart';
import 'package:notes/sync/caldav_remote.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_study_calendar.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository notes;
  late CardRepository cards;
  late TaskRepository tasks;
  late FakeStudyCalendar calendar;
  late StudyPlanner planner;
  late String noteId;
  // Monday 1 June 2026, 8 o'clock
  var now = DateTime(2026, 6, 1, 8);

  Future<void> real(WidgetTester tester, [int times = 6]) async {
    for (var i = 0; i < times; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50)); // (and the page transitions move on)
    }
  }

  /// Gives real time until [done] holds (each step of real IO needs a turn of the real loop and then a pump).
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await real(tester, 1);
    }
    expect(done(), isTrue, reason: 'waited too long');
    await real(tester, 2);
  }

  Future<void> approve(WidgetTester tester) async {
    final before = planner.plans.map((p) => p.sessions.length).toList();
    await tester.tap(find.byKey(const ValueKey('study-approve')));
    await until(tester, () => find.byKey(const ValueKey('study-approve')).evaluate().isEmpty);
    await tester.pumpAndSettle();
    expect(planner.plans, isNotEmpty, reason: 'approved (before: $before)');
  }

  Future<void> open(WidgetTester tester, {Size size = const Size(1000, 1400), bool withCards = true}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    now = DateTime(2026, 6, 1, 8);
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['settings', 'tasks', 'review_cards', 'notes']) {
        await db.delete(t);
      }
      notes = NoteRepository(db);
      cards = CardRepository(db);
      tasks = TaskRepository(db);
      calendar = FakeStudyCalendar();
      noteId = await notes.createNote(title: 'Biology notes');
      if (withCards) await cards.addAll(noteId, [for (var i = 0; i < 20; i++) Flashcard('Question $i?', 'Answer $i')], now: now);
      planner = StudyPlanner(SettingsRepository(db), cards, tasks,
          calendar: calendar,
          readNote: (id) async => NoteShape(
                noteId: id,
                title: 'Biology notes',
                pdfPages: 30,
                pdfOutline: const [(title: 'Cells', level: 1, page: 0), (title: 'Genetics', level: 1, page: 10), (title: 'Evolution', level: 1, page: 20)],
              ),
          now: () => now);
      await planner.load();
    });
    await tester.pumpWidget(MaterialApp(home: StudyPlanScreen(planner: planner, repository: notes, clock: () => now)));
    await real(tester, 2);
  }

  Future<void> makePlan(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('new-study-plan')));
    await tester.pump();
    await real(tester, 4);
    await tester.pumpAndSettle();
    final see = find.byKey(const ValueKey('study-see'));
    if (see.evaluate().isNotEmpty) expect(tester.widget<FilledButton>(see).onPressed, isNull, reason: 'it needs a name');
    await tester.enterText(find.byKey(const ValueKey('study-name')), 'Biology');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('study-add-note')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('pick-note-$noteId')));
    await tester.pumpAndSettle();
    await real(tester, 3);
    expect(find.byKey(ValueKey('study-unit-$noteId#0')), findsOneWidget);
    expect(find.text('Cells'), findsOneWidget);
    expect(find.text('Evolution'), findsOneWidget);

    // Evolution is left out; Genetics is hard
    await tester.tap(find.byKey(ValueKey('study-unit-on-$noteId#2')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('study-unit-diff-$noteId#1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hard').last);
    await tester.pumpAndSettle();
    expect(find.text('60 min'), findsOneWidget, reason: 'ten pages at four minutes, half as long again');

    await tester.scrollUntilVisible(see, 200, scrollable: find.descendant(of: find.byKey(const ValueKey('study-setup-list')), matching: find.byType(Scrollable)).first);
    await tester.pumpAndSettle();
    await tester.tap(see);
    await until(tester, () => find.byKey(const ValueKey('study-summary')).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
  }

  testWidgets('a new plan: the material, the time, the proposal; nothing is written before it is approved', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('study-plans-empty')), findsOneWidget);
    await makePlan(tester);

    expect(find.byKey(const ValueKey('study-summary')), findsOneWidget);
    expect(find.textContaining('Learn: Cells'), findsWidgets);
    expect(find.textContaining('Evolution'), findsNothing, reason: 'left out');
    expect(find.byKey(const ValueKey('study-target-label')), findsOneWidget);
    expect(find.text('A new "Study" calendar on this device'), findsOneWidget);
    expect(calendar.written, isEmpty);
    expect((await tester.runAsync(() => tasks.listTasks()))!, isEmpty);

    await approve(tester);

    final plan = planner.plans.single;
    expect(plan.name, 'Biology');
    expect(plan.units.firstWhere((u) => u.title == 'Genetics').difficulty, Difficulty.hard);
    expect(plan.units.firstWhere((u) => u.title == 'Evolution').included, isFalse);
    expect(plan.cardSources, {noteId});
    expect(calendar.made, [CalendarPlace.phone]);
    expect(calendar.written.length, plan.sessions.length);
    expect((await tester.runAsync(() => tasks.listTasks()))!.length, plan.sessions.length);
    // back on the list
    expect(find.byKey(ValueKey('study-plan-${plan.id}')), findsOneWidget);
    expect(find.textContaining('14 days left'), findsOneWidget);
    expect(find.textContaining('Next: '), findsOneWidget);
    expect(find.text('0 % of the material learnt'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a session can be refused: the plan is made again without that time', (tester) async {
    await open(tester);
    await makePlan(tester);
    final first = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('study-refuse-')).first;
    final key = (tester.widget(first).key! as ValueKey<String>).value.substring('study-refuse-'.length);
    await tester.tap(first);
    await until(tester, () => find.byKey(ValueKey('study-session-$key')).evaluate().isEmpty);
    await tester.pumpAndSettle();
    await approve(tester);
    final plan = planner.plans.single;
    expect(plan.blocked, hasLength(1));
    expect(plan.sessions.where((s) => s.key == key), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a missed session and a clashing event are said on the plan; making it again shows the changes and applies them', (tester) async {
    await open(tester);
    await makePlan(tester);
    await approve(tester);
    final plan = planner.plans.single;
    final first = plan.sessions.first, later = plan.sessions[3];
    await tester.runAsync(() async {
      calendar.others.add(DayEvent(title: 'Dentist', start: later.session.start, end: later.session.end, allDay: false, calendarName: 'Private', calendarKey: 'phone:p'));
      now = first.session.end.add(const Duration(minutes: 1));
      await planner.refresh();
    });
    await tester.pump();
    expect(find.byKey(ValueKey('study-attention-${plan.id}')), findsOneWidget);
    expect(find.text('1 session went by without being ticked off.'), findsOneWidget);
    expect(find.text('1 session now clashes with an event.'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('study-replan-${plan.id}')));
    await until(tester, () => find.byKey(const ValueKey('study-summary')).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.text('Apply the changes'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Dentist'), 200, scrollable: find.descendant(of: find.byKey(const ValueKey('study-proposal-list')), matching: find.byType(Scrollable)).first);
    expect(find.text('Dentist'), findsOneWidget, reason: 'the events are shown among the sessions');
    expect(find.byKey(ValueKey('study-session-${later.key}')), findsNothing);
    expect(find.byKey(ValueKey('study-removed-${later.key}')), findsOneWidget, reason: 'the session that clashes is shown as taken away');
    await approve(tester);
    expect(find.byKey(ValueKey('study-attention-${plan.id}')), findsNothing);
    expect(calendar.written.containsKey(later.eventId), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('deleting a plan asks first, then takes its sessions off the calendar and the to-dos', (tester) async {
    await open(tester);
    await makePlan(tester);
    await approve(tester);
    final plan = planner.plans.single;
    await tester.tap(find.byKey(ValueKey('study-menu-${plan.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('study-remove-${plan.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('study-delete-confirm')));
    await until(tester, () => planner.plans.isEmpty);
    expect(find.byKey(const ValueKey('study-plans-empty')), findsOneWidget);
    expect(calendar.written, isEmpty);
    expect((await tester.runAsync(() => tasks.listTasks()))!, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('on a phone the setup and the proposal fit the width', (tester) async {
    await open(tester, size: const Size(400, 860));
    await makePlan(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('study-approve')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the review of the cards has the button to the plans, when plans are offered', (tester) async {
    await open(tester);
    await tester.pumpWidget(MaterialApp(home: ReviewScreen(cards: cards, planner: planner, repository: notes, clock: () => now)));
    await real(tester, 3);
    expect(find.byKey(const ValueKey('study-plans')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('study-plans')));
    await tester.pumpAndSettle();
    expect(find.text('Study plans'), findsWidgets);
    expect(find.byKey(const ValueKey('new-study-plan')), findsOneWidget);
    await tester.pumpWidget(MaterialApp(home: ReviewScreen(cards: cards, clock: () => now)));
    await real(tester, 2);
    expect(find.byKey(const ValueKey('study-plans')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
