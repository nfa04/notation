import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/review/course.dart';
import 'package:notes/review/grades.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  final course = Course(
    folderId: 'f1',
    term: 'Autumn 2026',
    credits: 6,
    teacher: 'Prof. Keller',
    room: 'HG E 7',
    scale: GradeScale.swiss,
    target: 5,
    parts: [
      Assessment(id: 'm', name: 'Midterm', weight: 30, due: DateTime(2026, 11, 5), grade: 4.75),
      Assessment(id: 's', name: 'Sheet 6', kind: 'assignment', weight: 10, due: DateTime(2026, 12, 2)),
      const Assessment(id: 'f', name: 'Final', weight: 60),
    ],
    plans: const ['plan1'],
    eventPattern: 'Linear Algebra*',
  );

  test('a course goes to JSON and back', () {
    final back = Course.fromJson(course.toJson())!;
    expect([back.folderId, back.term, back.credits, back.teacher, back.room, back.scale, back.target, back.plans, back.eventPattern],
        ['f1', 'Autumn 2026', 6, 'Prof. Keller', 'HG E 7', GradeScale.swiss, 5, ['plan1'], 'Linear Algebra*']);
    expect(back.parts.map((p) => p.name), ['Midterm', 'Sheet 6', 'Final']);
    expect(Course.fromJson({'no': 'folder'}), isNull);
    expect(Course.fromJson(Course(folderId: 'x', removed: true).toJson())!.removed, isTrue);
  });

  test('its lectures are found by their name in the calendar', () {
    expect(course.isEvent('Linear Algebra - Lecture'), isTrue);
    expect(course.isEvent('linear algebra exercise'), isTrue);
    expect(course.isEvent('Analysis I'), isFalse);
    expect(const Course(folderId: 'x').isEvent('anything'), isFalse, reason: 'no pattern, no events');
    expect(const Course(folderId: 'x', eventPattern: 'Algo (CS 101)').isEvent('Algo (CS 101)'), isTrue, reason: 'brackets are plain letters');
  });

  test('what comes next: the parts not graded yet, the soonest first, the past left out', () {
    expect(course.upcoming(DateTime(2026, 11, 26)).map((p) => p.id), ['s', 'f']);
    expect(course.upcoming(DateTime(2026, 12, 3)).map((p) => p.id), ['f']);
    expect(course.goal, 5);
    expect(const Course(folderId: 'x', scale: GradeScale.german).goal, 4);
  });

  test('the courses are kept in the settings; a folder that is no longer a course stays out', () async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    await db.delete('settings');
    final settings = SettingsRepository(db);
    final repo = CourseRepository(settings);
    await repo.save(course);
    await repo.save(const Course(folderId: 'f2'));
    final again = CourseRepository(settings);
    await again.load();
    expect(again.courses.keys.toSet(), {'f1', 'f2'});
    expect(again.of('f1')!.parts, hasLength(3));
    await again.remove('f2');
    final third = CourseRepository(settings);
    await third.load();
    expect(third.courses.keys, ['f1']);
    expect(await settings.get('${CourseRepository.keyPrefix}f2'), contains('removed'), reason: 'kept as removed, so the other devices hear of it');
    await db.close();
  });
}
