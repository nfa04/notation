import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/event_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  migrationTests();
  setUpAll(AppDatabase.initFfi);

  late EventRepository repo;
  setUp(() async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    await db.delete('local_events'); // the in-memory database is shared between tests
    await db.delete('local_calendars');
    repo = EventRepository(db);
  });

  LocalEvent event(String title, DateTime start, {Duration length = const Duration(hours: 1), String? calendar, String? rrule}) => LocalEvent(
        id: '',
        calendarId: calendar ?? EventRepository.defaultCalendarId,
        title: title,
        start: start,
        end: start.add(length),
        rrule: rrule,
      );

  test('there is always a calendar to put an event in', () async {
    final calendars = await repo.calendars();
    expect(calendars.map((c) => c.id), [EventRepository.defaultCalendarId]);
    expect((await repo.calendars()).length, 1);
  });

  test('create, read back, edit, delete', () async {
    await repo.calendars();
    final id = await repo.createEvent(LocalEvent(
      id: '',
      calendarId: EventRepository.defaultCalendarId,
      title: 'Lecture',
      start: DateTime(2026, 11, 26, 10),
      end: DateTime(2026, 11, 26, 12),
      location: 'Room 4',
      alarms: const [10, 60],
      exdates: [DateTime(2026, 12, 3, 10)],
      rrule: 'FREQ=WEEKLY',
    ));
    final read = (await repo.event(id))!;
    expect(read.title, 'Lecture');
    expect(read.start, DateTime(2026, 11, 26, 10));
    expect(read.location, 'Room 4');
    expect(read.alarms, [10, 60]);
    expect(read.exdates, [DateTime(2026, 12, 3, 10)]);
    expect(read.repeats, isTrue);

    await repo.updateEvent(read.copyWith(title: 'Lecture 2', location: null, rrule: null));
    final changed = (await repo.event(id))!;
    expect(changed.title, 'Lecture 2');
    expect(changed.location, isNull);
    expect(changed.repeats, isFalse);
    expect(changed.alarms, [10, 60]);

    await repo.deleteEvent(id);
    expect(await repo.event(id), isNull);
  });

  test('eventsIn finds overlapping events, and repeating ones that started before', () async {
    await repo.calendars();
    await repo.createEvent(event('inside', DateTime(2026, 11, 26, 9)));
    await repo.createEvent(event('before', DateTime(2026, 11, 20, 9)));
    await repo.createEvent(event('crossing', DateTime(2026, 11, 25, 23), length: const Duration(hours: 3)));
    await repo.createEvent(event('weekly', DateTime(2026, 10, 1, 9), rrule: 'FREQ=WEEKLY'));
    await repo.createEvent(event('after', DateTime(2026, 11, 27, 9)));

    final titles = (await repo.eventsIn(DateTime(2026, 11, 26), DateTime(2026, 11, 27))).map((e) => e.title).toList();
    expect(titles, ['weekly', 'crossing', 'inside']);
  });

  test('a hidden or deleted calendar takes its events off the calendar', () async {
    await repo.calendars();
    final other = await repo.createCalendar('Uni');
    await repo.createEvent(event('mine', DateTime(2026, 11, 26, 9)));
    await repo.createEvent(event('uni', DateTime(2026, 11, 26, 10), calendar: other));
    final day = (DateTime(2026, 11, 26), DateTime(2026, 11, 27));

    expect((await repo.eventsIn(day.$1, day.$2)).length, 2);
    await repo.updateCalendar(other, hidden: true);
    expect((await repo.eventsIn(day.$1, day.$2)).map((e) => e.title), ['mine']);
    await repo.updateCalendar(other, hidden: false);
    await repo.deleteCalendar(other);
    expect((await repo.eventsIn(day.$1, day.$2)).map((e) => e.title), ['mine']);
    expect((await repo.calendars()).map((c) => c.id), [EventRepository.defaultCalendarId]);
  });

  test('search matches title, place and notes without treating % as a wildcard', () async {
    await repo.calendars();
    await repo.createEvent(event('Dentist', DateTime(2026, 11, 26, 9)));
    await repo.createEvent(event('100% effort', DateTime(2026, 11, 27, 9)));
    expect((await repo.search('dent')).map((e) => e.title), ['Dentist']);
    expect((await repo.search('%')).map((e) => e.title), ['100% effort']);
  });

  test('changes fire after a write', () async {
    await repo.calendars();
    var fired = 0;
    final sub = repo.changes.listen((_) => fired++);
    await repo.createEvent(event('x', DateTime(2026, 11, 26, 9)));
    await Future<void>.delayed(Duration.zero);
    expect(fired, 1);
    await sub.cancel();
  });
}

void migrationTests() {
  Future<Set<String>> columns(Database db) async => {for (final r in await db.rawQuery('PRAGMA table_info(local_events)')) r['name'] as String};

  for (final from in [59, 60]) {
    test('a database at version $from gets the attendees column when it is opened', () async {
      final dir = await Directory.systemTemp.createTemp('events_migration');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/notes.db';
      var db = await AppDatabase.open(path: path);
      // (put the file back the way a build of that version left it)
      if (from == 59) {
        await db.execute('DROP TABLE local_events');
        await db.execute('DROP TABLE local_calendars');
      } else {
        await db.execute('ALTER TABLE local_events DROP COLUMN attendees');
      }
      await db.execute('PRAGMA user_version = $from');
      await db.close();

      db = await AppDatabase.open(path: path);
      expect(await columns(db), containsAll(['alarms', 'attendees', 'location']));
      final repo = EventRepository(db);
      await repo.calendars();
      final id = await repo.createEvent(LocalEvent(
        id: '', calendarId: EventRepository.defaultCalendarId, title: 'x', start: DateTime(2026, 12, 1, 9), end: DateTime(2026, 12, 1, 10), attendees: const ['a@b.c']));
      expect((await repo.event(id))!.attendees, ['a@b.c']);
      await db.close();
    });
  }
}
