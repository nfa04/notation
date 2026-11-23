import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:notes/algebra/mistake_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/graph/study.dart';
import 'package:notes/review/study_calendar.dart';
import 'package:notes/review/study_generate.dart';
import 'package:notes/review/study_material.dart';
import 'package:notes/review/study_planner.dart';
import 'package:notes/review/study_practice.dart';
import 'package:notes/review/study_schedule.dart';
import 'package:notes/review/study_topics.dart';
import 'package:notes/screens/study_plan_screen.dart';
import 'package:notes/screens/study_session_screen.dart';
import 'package:notes/sync/caldav_remote.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_study_calendar.dart';
import 'support/fake_model.dart';

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
  // the notes the sessions opened, at their pages
  final opened = <(String, int?)>[];

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

  Future<void> open(WidgetTester tester, {Size size = const Size(1000, 1400), bool withCards = true, bool outline = true}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    now = DateTime(2026, 6, 1, 8);
    opened.clear();
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
                pdfOutline: outline ? const [(title: 'Cells', level: 1, page: 0), (title: 'Genetics', level: 1, page: 10), (title: 'Evolution', level: 1, page: 20)] : const [],
              ),
          now: () => now);
      await planner.load();
    });
    await tester.pumpWidget(MaterialApp(
        home: StudyPlanScreen(planner: planner, repository: notes, clock: () => now, cards: cards, onOpenNoteAt: (id, page) => opened.add((id, page)))));
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
    expect(find.text('0 %'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a plan can be viewed: its parts and every session by day, and the list says how far each plan is', (tester) async {
    await open(tester);
    await makePlan(tester);
    await approve(tester);
    final plan = planner.plans.single;
    expect(find.textContaining('sessions done'), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-progress')), findsOneWidget);
    expect(find.text('ready for the exam'), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-pace')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('study-detail-${plan.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-detail')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-tabs')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-progress')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-next-up')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-diagram')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-week')), findsOneWidget);
    // pointing at the diagram says how ready the plan is that day and what is still to learn by then
    final area = find.byKey(const ValueKey('plan-diagram-area'));
    await tester.ensureVisible(area);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getTopRight(area) - const Offset(40, -40));
    await tester.pump();
    expect(find.textContaining('Still to learn by then'), findsOneWidget);
    expect(find.textContaining('Planned: 100 %'), findsWidgets);
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(find.byKey(const ValueKey('plan-diagram-tip')), findsNothing);
    // the parts and the sessions are tabs of their own
    expect(find.byKey(ValueKey('plan-part-${plan.units.first.id}')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('plan-tab-parts')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-diagram')), findsNothing);
    expect(find.byKey(ValueKey('plan-part-sessions-${plan.units.first.id}')), findsOneWidget);
    expect(find.text('Not started'), findsWidgets);
    expect(find.byKey(ValueKey('plan-part-${plan.units.first.id}')), findsOneWidget);
    final first = plan.sessions.first;
    await tester.tap(find.byKey(const ValueKey('plan-tab-sessions')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(ValueKey('plan-session-${first.key}')), 200, scrollable: find.descendant(of: find.byKey(const ValueKey('plan-detail')), matching: find.byType(Scrollable)).first);
    expect(find.byKey(ValueKey('plan-session-${first.key}')), findsOneWidget);
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

  testWidgets('a session: opened from the plan, its clock, its note at the page, and at the end what was done and how it went', (tester) async {
    await open(tester);
    await makePlan(tester);
    await approve(tester);
    final plan = planner.plans.single;
    // (a day with something to learn; the plan opens that day's session)
    final s = plan.sessions.firstWhere((s) => s.session.items.any((i) => i.kind == WorkKind.learn));
    final learn = s.session.items.indexWhere((i) => i.kind == WorkKind.learn);
    now = s.session.start.subtract(const Duration(hours: 2));
    await tester.runAsync(planner.refresh); // (the list is shown anew at the new time)
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('study-open-${plan.id}')));
    await tester.pumpAndSettle();
    expect(find.text('00:00'), findsOneWidget);
    expect(find.byKey(const ValueKey('session-start')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('session-start')));
    await until(tester, () => planner.running != null);
    now = now.add(const Duration(minutes: 7));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('07:00'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('session-item-$learn')));
    await until(tester, () => planner.running!.checked.contains(learn));

    // the note opens at the part's page; the clock goes on, and the plan offers to go on with the session
    final unit = plan.unit(s.session.items[learn].unitId!)!;
    await tester.tap(find.byKey(ValueKey('session-open-$learn')));
    await tester.pumpAndSettle();
    expect(opened.single, (noteId, pageOf(s.session.items[learn], unit)));
    expect(find.text('Go on with the session'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('study-open-${plan.id}')));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(find.byKey(ValueKey('session-item-$learn'))).value, isTrue, reason: 'the tick is kept');

    now = now.add(const Duration(minutes: 33));
    await tester.tap(find.byKey(const ValueKey('session-finish')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('session-minutes'))).controller!.text, '40');
    expect(tester.widget<CheckboxListTile>(find.byKey(ValueKey('session-done-$learn'))).value, isTrue);
    await tester.tap(find.byKey(const ValueKey('session-feel-hard')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('session-save')));
    await tester.tap(find.byKey(const ValueKey('session-save')));
    await until(tester, () => find.byKey(const ValueKey('session-saved')).evaluate().isNotEmpty);
    expect(find.textContaining('1 of ${s.session.items.length} done, in 40 minutes.'), findsOneWidget);
    expect(find.textContaining('now counts as harder.'), findsOneWidget);
    expect(find.textContaining('ready for the exam: now'), findsOneWidget);
    final kept = planner.plans.single;
    expect(kept.sessions.firstWhere((x) => x.key == s.key).report!.spent, 40);
    expect(kept.learned, greaterThan(0));
    expect(planner.running, isNull);
    await tester.tap(find.byKey(const ValueKey('session-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('study-plan-${plan.id}')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a session\'s practice: the lines that were wrong (with what was wrong, and their page) and the quiz on the part\'s facts', (tester) async {
    await open(tester);
    final facts = _Facts([for (var i = 0; i < 4; i++) (noteId: noteId, page: i, fact: StudyFact('Cell $i', 'Cells do thing $i.'))]);
    late StudyPlanEntry plan;
    await tester.runAsync(() async {
      await cards.addAll(noteId, [Flashcard('${mistakeFront}a+b=ab', 'Not a product.', page: 3)]);
      planner.facts = facts;
      final units = await planner.unitsOf(noteId);
      plan = await planner.approve(await planner.propose(planner.draft(name: 'Biology', exam: DateTime(2026, 6, 12)).copyWith(units: units, cardSources: () => const {})));
    });
    final s = plan.sessions.firstWhere((s) => s.session.items.any((i) => i.kind == WorkKind.mistakes));
    final m = s.session.items.indexWhere((i) => i.kind == WorkKind.mistakes), q = s.session.items.indexWhere((i) => i.kind == WorkKind.quiz);
    expect(q, m + 1);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => openStudySession(context, planner, plan.id, s.key, cards: cards, onOpenNoteAt: (id, page) => opened.add((id, page)), clock: () => now),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Do the lines you got wrong again: Cells'), findsOneWidget);
    expect(find.text('Quiz yourself: Cells'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('session-quiz-$q')));
    await until(tester, () => facts.asked.isNotEmpty);
    expect(facts.asked.single, ('Cells', 4));
    expect(planner.running?.key, s.key, reason: 'opening a piece of work starts the clock');

    await tester.tap(find.byKey(ValueKey('session-mistakes-$m')));
    await until(tester, () => find.byKey(const ValueKey('mistake-0')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('mistake-back-0')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mistake-show-0')));
    await tester.pump();
    expect(find.text('Not a product.'), findsOneWidget);
    expect(find.text('Open page 4'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mistake-open-0')));
    await tester.pumpAndSettle();
    expect(opened.single, (noteId, 3));
    expect(find.text('go'), findsOneWidget, reason: 'the session is left for the note, its clock goes on');
    expect(planner.running?.key, s.key);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the dashboard\'s card offers today\'s session and says how long it has been studied', (tester) async {
    await open(tester);
    await makePlan(tester);
    await approve(tester);
    final s = planner.plans.single.sessions.first;
    now = DateTime(s.session.start.year, s.session.start.month, s.session.start.day, 8);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StudySessionCard(planner: planner, cards: cards, clock: () => now))));
    await tester.pump();
    expect(find.text(s.title), findsOneWidget);
    expect(find.textContaining('Today at '), findsOneWidget);
    await tester.runAsync(() => planner.begin(planner.plans.single.id, s.key));
    now = now.add(const Duration(minutes: 12));
    await tester.pump();
    expect(find.text('Studying for 12 min'), findsOneWidget);
    expect(find.text('Go on'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('study-session-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('session-clock')), findsOneWidget);
    // a day without sessions: no card
    await tester.runAsync(() => planner.abandon());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StudySessionCard(planner: planner, clock: () => DateTime(2026, 7, 1)))));
    expect(find.byKey(const ValueKey('study-session-card')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('a PDF without a table of contents is cut by its topics with the AI model, when the person asks for it', (tester) async {
    await open(tester, outline: false);
    final model = FakeModel('1-12 | Cells\n13-30 | Genetics');
    planner.topics = StudyTopicSplitter(pageTexts: (_) async => {for (var p = 0; p < 30; p++) p: 'The text of page ${p + 1} of the course'}, model: () => model, enabled: () => true);
    await tester.tap(find.byKey(const ValueKey('new-study-plan')));
    await tester.pump();
    await real(tester, 4);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('study-add-note')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('pick-note-$noteId')));
    await tester.pumpAndSettle();
    await real(tester, 3);
    expect(find.text('Pages 1-8'), findsOneWidget, reason: 'cut by page number');
    await tester.tap(find.byKey(ValueKey('study-split-$noteId')));
    await until(tester, () => find.text('Genetics').evaluate().isNotEmpty);
    expect(find.byKey(ValueKey('study-unit-$noteId#p0')), findsOneWidget);
    expect(find.byKey(ValueKey('study-unit-$noteId#p12')), findsOneWidget);
    expect(find.text('Pages 1-8'), findsNothing);
    expect(find.text('48 min'), findsOneWidget, reason: 'twelve pages at four minutes');
    expect(find.byKey(ValueKey('study-split-$noteId')), findsNothing, reason: 'nothing is cut by page number any more');
    expect(model.prompts.single.user, contains('Page 30: The text of page 30'));
  });


  testWidgets('summaries and flashcards are made for the parts when the person asks, and a session reads the summary and opens the note from anywhere', (tester) async {
    await open(tester, outline: false);
    final model = FakeModel()
      ..respond = (p) => p.system.contains('flashcards') ? 'Q: What is a cell?\nA: The unit of life.\n\nQ: What makes ATP?\nA: Mitochondria.\n\nQ: What is a membrane?\nA: A barrier.' : '- A cell is the unit of life.\n- Mitochondria make ATP.\n- A membrane is a barrier.';
    planner.maker = StudyMaterialMaker(
        pageTexts: (_) async => {for (var p = 0; p < 30; p++) p: 'The text of page ${p + 1} of the course about cells and their membranes'},
        documentText: (_) async => '',
        model: () => model,
        enabled: () => true);
    await tester.tap(find.byKey(const ValueKey('new-study-plan')));
    await tester.pump();
    await real(tester, 4);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('study-make')), findsNothing, reason: 'no parts yet: nothing to make');
    await tester.tap(find.byKey(const ValueKey('study-add-note')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('pick-note-$noteId')));
    await tester.pumpAndSettle();
    await real(tester, 3);
    final before = (await tester.runAsync(() => cards.all(source: noteId)))!.length;
    await tester.ensureVisible(find.byKey(const ValueKey('study-make')));
    await tester.tap(find.byKey(const ValueKey('study-make')));
    await until(tester, () => find.byKey(const ValueKey('study-made')).evaluate().isNotEmpty);
    expect(find.text('Made for 4 parts and 3 new flashcards.'), findsOneWidget, reason: 'the same three cards of every part are one card each');
    expect(find.byKey(const ValueKey('study-make-again')), findsOneWidget);
    expect((await tester.runAsync(() => cards.all(source: noteId)))!.length, before + 3);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a session shows the summary of its part, and the note opens above every screen that was open', (tester) async {
    await open(tester);
    late StudyPlanEntry plan;
    await tester.runAsync(() async {
      final units = await planner.unitsOf(noteId);
      final draft = planner.draft(name: 'Biology', exam: DateTime(2026, 6, 12)).copyWith(units: units, cardSources: () => const {});
      plan = await planner.approve(await planner.propose(draft.copyWith(material: {for (final u in units) u.id: const UnitMaterial(points: ['A cell is the unit of life.', 'Mitochondria make ATP.'], cards: 2)})));
    });
    expect(plan.material, isNotEmpty);
    final s = plan.sessions.first;
    final i = s.session.items.indexWhere((x) => x.kind == WorkKind.learn);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                  builder: (_) => StudyPlanScreen(planner: planner, repository: notes, clock: () => now, cards: cards, onOpenNoteAt: (id, page) => opened.add((id, page))))),
          child: const Text('plans'),
        ),
      ),
    ));
    await tester.tap(find.text('plans'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('study-open-${plan.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('session-summary-$i')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('session-summary-$i')));
    await tester.pumpAndSettle();
    expect(find.text('Mitochondria make ATP.'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('session-open-$i')));
    await tester.pumpAndSettle();
    expect(opened, isNotEmpty);
    expect(find.text('plans'), findsOneWidget, reason: 'the session and the plans are both left: the note is what shows');
    await tester.pumpWidget(const SizedBox());
  });

}

/// Facts of graphs; the quizzes asked for are kept (the title, and how many facts).
class _Facts implements StudyFactSource {
  final List<FactSpot> spots;
  final asked = <(String, int)>[];
  _Facts(this.spots);

  @override
  bool get canQuiz => true;

  @override
  Future<List<FactSpot>> facts() async => spots;

  @override
  Future<void> quiz(BuildContext context, String title, List<StudyFact> facts, {CardRepository? cards}) async => asked.add((title, facts.length));

}
