import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/review/course.dart';
import 'package:notes/review/grades.dart';
import 'package:notes/screens/folder_view.dart';
import 'package:notes/screens/learning_hub.dart';
import 'package:notes/sync/caldav_remote.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late CardRepository cards;
  late CourseRepository courses;
  late String folder;

  Future<void> setUpData(WidgetTester tester) => tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('course_');
        addTearDown(() => dir.delete(recursive: true));
        final db = await AppDatabase.open(path: '${dir.path}/n.db');
        repo = NoteRepository(db);
        cards = CardRepository(db);
        courses = CourseRepository(repo.settings);
        folder = await repo.createFolder('Linear Algebra');
        final lecture = await repo.createNote(title: 'Lecture 1', folderId: folder);
        await repo.createNote(title: 'Elsewhere');
        await cards.addAll(lecture, const [Flashcard('Q1', 'A1'), Flashcard('Q2', 'A2')]);
        await cards.addAll('other-note', const [Flashcard('Q3', 'A3')]);
      });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('a folder is made a course: its details, a graded part, the grade with what is needed, its cards and its next lecture', (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await setUpData(tester);
    final lecture = DateTime.now().add(const Duration(days: 2));
    final tasks = <(String, DateTime)>[];
    await tester.pumpWidget(MaterialApp(
      home: FolderView(
        repository: repo,
        onOpenNote: (_) {},
        courses: courses,
        cards: cards,
        events: (from, to) async => [
          DayEvent(title: 'Linear Algebra - Lecture', start: lecture, end: lecture.add(const Duration(hours: 2)), allDay: false, calendarName: 'Uni'),
          DayEvent(title: 'Analysis', start: lecture, end: lecture, allDay: false, calendarName: 'Uni'),
        ],
        onAddTask: (title, due) async => tasks.add((title, due)),
      ),
    ));
    await settle(tester);

    // the folder's menu makes it a course
    await tester.tap(find.byTooltip('Folder actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make this a course'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('course-term')), 'Autumn 2026');
    await tester.enterText(find.byKey(const ValueKey('course-credits')), '6');
    await tester.enterText(find.byKey(const ValueKey('course-events')), 'Linear Algebra*');
    await tester.tap(find.byKey(const ValueKey('course-scale')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Swiss (1-6, 6 best)').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('course-target')), '5');

    // a midterm with points, and the final still to come
    for (final (name, weight, points) in [('Midterm', '40', '27'), ('Final', '60', '')]) {
      await tester.tap(find.byKey(const ValueKey('course-add-part')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('part-name')), name);
      await tester.enterText(find.byKey(const ValueKey('part-weight')), weight);
      if (points.isNotEmpty) {
        await tester.enterText(find.byKey(const ValueKey('part-points')), points);
        await tester.enterText(find.byKey(const ValueKey('part-max')), '30');
      }
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('part-save')));
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const ValueKey('course-dialog-grade')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('course-save')));
    await settle(tester);

    final course = courses.of(folder)!;
    expect([course.term, course.credits, course.scale, course.target], ['Autumn 2026', 6, GradeScale.swiss, 5]);
    expect(course.parts.map((p) => p.name), ['Midterm', 'Final']);
    // 27/30 = 90 % -> 1 + 5 x 0.9 = 5.5; for 5 overall the final needs (500 - 40 x 5.5) / 60 = 4.67
    expect(find.text('5.5'), findsOneWidget);
    expect(find.text('For 5: 4.67 on average on what is left.'), findsOneWidget);
    expect(find.text('2 cards to review'), findsOneWidget, reason: 'only the cards of the notes in the folder');
    expect(find.byKey(const ValueKey('course-next-lecture')), findsOneWidget);
    expect(find.text('Autumn 2026 · 6 credits'), findsOneWidget);

    // a course is kept in the settings, for the other devices
    final again = CourseRepository(repo.settings);
    await tester.runAsync(again.load);
    expect(again.of(folder)!.parts, hasLength(2));
  });

  testWidgets('the learning hub lists the courses by term with their grades and the average by credits', (tester) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await setUpData(tester);
    late String second;
    await tester.runAsync(() async {
      second = await repo.createFolder('Algorithms');
      await courses.save(Course(folderId: folder, term: 'Autumn 2026', credits: 6, scale: GradeScale.swiss, parts: const [Assessment(id: 'a', name: 'Final', grade: 5)]));
      await courses.save(Course(folderId: second, term: 'Autumn 2026', credits: 3, scale: GradeScale.swiss, parts: const [Assessment(id: 'b', name: 'Final', grade: 4)]));
    });
    await tester.pumpWidget(MaterialApp(home: LearningHub(repository: repo, cards: cards, courses: courses)));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('hub-tab-courses')));
    await settle(tester);
    expect(find.text('Linear Algebra'), findsOneWidget);
    expect(find.text('Algorithms'), findsOneWidget);
    expect(find.text('Average by credits: 4.67'), findsOneWidget);
  });
}
