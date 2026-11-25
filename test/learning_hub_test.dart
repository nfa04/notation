import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/review/study_planner.dart';
import 'package:notes/screens/learning_hub.dart';
import 'package:notes/screens/review_export.dart' show ankiSourcePrefix;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository notes;
  late CardRepository cards;
  late TaskRepository tasks;
  late SettingsRepository settings;
  final now = DateTime(2026, 6, 1, 8);

  Future<void> data(WidgetTester tester, Future<void> Function() fill) => tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        for (final t in ['settings', 'tasks', 'review_cards', 'notes']) {
          await db.delete(t);
        }
        notes = NoteRepository(db);
        cards = CardRepository(db);
        tasks = TaskRepository(db);
        settings = SettingsRepository(db);
        await fill();
      });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  group('the learning hub', () {
    testWidgets('lists the cards by where they came from, with what is due, and reviews one source', (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await data(tester, () async {
        final lecture = await notes.createNote(title: 'Lecture 3');
        await cards.addAll(lecture, const [Flashcard('Q1', 'A1'), Flashcard('Q2', 'A2')], now: now);
        await cards.addAll('${ankiSourcePrefix}Verbs', const [Flashcard('ser', 'to be')], now: now.add(const Duration(days: 3)));
        await cards.addAll(CardRepository.graphSource, const [Flashcard('ATP?', 'Energy')], now: now);
      });
      await tester.pumpWidget(MaterialApp(home: LearningHub(repository: notes, cards: cards, clock: () => now)));
      await settle(tester);

      expect(find.text('Lecture 3'), findsOneWidget);
      expect(find.text('Anki: Verbs'), findsOneWidget);
      expect(find.text('Facts of the graph'), findsOneWidget);
      expect(find.text('2 cards · 2 due'), findsOneWidget);
      expect(find.text('1 card · none due'), findsOneWidget, reason: 'the Anki card is due in three days');
      expect(find.text('3 cards to review'), findsOneWidget, reason: 'today: every card that is due');
      expect(find.text('Exams'), findsNothing, reason: 'no calendar, no plans');

      final lecture = (await tester.runAsync(() => notes.listNotes()))!.single.id;
      await tester.tap(find.byKey(ValueKey('deck-$lecture')));
      await settle(tester);
      expect(find.text('2 left'), findsOneWidget, reason: 'only the cards of that note');
    });

    testWidgets('with no cards it says how to get some, and with a planner it offers a plan', (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late StudyPlanner planner;
      await data(tester, () async {
        planner = StudyPlanner(settings, cards, tasks, now: () => now);
        await planner.load();
      });
      await tester.pumpWidget(MaterialApp(home: LearningHub(repository: notes, cards: cards, planner: planner, clock: () => now)));
      await settle(tester);
      expect(find.byKey(const ValueKey('hub-no-cards')), findsOneWidget);
      expect(find.byKey(const ValueKey('hub-nothing-due')), findsOneWidget);
      expect(find.byKey(const ValueKey('study-plans-empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('new-study-plan')), findsOneWidget);
    });
  });

  group('the "Learn today" row', () {
    testWidgets('is not there when nothing is due, and counts the cards and opens the hub when some are', (tester) async {
      await data(tester, () async {});
      var opened = 0;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: LearnTodayRow(cards: cards, repository: notes, onOpenHub: () => opened++, clock: () => now))));
      await settle(tester);
      expect(find.byKey(const ValueKey('learn-today')), findsNothing);

      await tester.runAsync(() => cards.addAll('n1', const [Flashcard('Q', 'A'), Flashcard('Q2', 'A2')], now: now));
      await settle(tester);
      expect(find.text('Learn today'), findsOneWidget);
      expect(find.text('2 cards to review'), findsOneWidget);
      expect(find.byKey(const ValueKey('learn-today-review')), findsOneWidget, reason: 'no session today: the button reviews the cards');
      await tester.tap(find.text('Learn today'));
      expect(opened, 1);
    });
  });
}
