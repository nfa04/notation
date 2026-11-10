import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/screens/caldav_settings_screen.dart';
import 'package:notes/sync/ics.dart';
import 'package:notes/sync/ics_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String ics(String events, {String header = ''}) =>
    'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//test//EN\r\n$header${events.trim().replaceAll('\n', '\r\n')}\r\nEND:VCALENDAR\r\n';

String event(String lines, {String uid = 'u1'}) => 'BEGIN:VEVENT\nUID:$uid\n${lines.trim()}\nEND:VEVENT\n';

List<String> days(List<dynamic> events) => [for (final e in events) '${e.start.year}-${e.start.month.toString().padLeft(2, '0')}-${e.start.day.toString().padLeft(2, '0')}'];

List<dynamic> expand(String text, String from, String to) =>
    expandIcs(parseIcs(text), DateTime.parse(from), DateTime.parse(to), calendarName: 'Cal', key: 'ics:t');

void main() {
  setUpAll(AppDatabase.initFfi);

  group('reading a file', () {
    test('names, folded lines, escapes, all-day and timed events', () {
      final cal = parseIcs(ics(
        event('''
SUMMARY:Lecture\\, Physics 1\\nRoom B12 with a very long
  title that was folded
DTSTART:20260310T080000Z
DTEND:20260310T093000Z
LOCATION:Main hall''') +
            event('''
SUMMARY:Holiday
DTSTART;VALUE=DATE:20260401
DTEND;VALUE=DATE:20260404''', uid: 'u2'),
        header: 'X-WR-CALNAME:Uni timetable\nX-APPLE-CALENDAR-COLOR:#FF2968FF\n',
      ));
      expect(cal.name, 'Uni timetable');
      expect(cal.color, '#FF2968');
      expect(cal.events.length, 2);
      expect(cal.events.first.summary, startsWith('Lecture, Physics 1\nRoom B12 with a very long title'));
      expect(cal.events.first.location, 'Main hall');

      final shown = expandIcs(cal, DateTime(2026, 3, 1), DateTime(2026, 5, 1), calendarName: 'Uni', key: 'ics:t');
      expect(shown.length, 2);
      final lecture = shown.first;
      expect(lecture.allDay, isFalse);
      expect(lecture.start.toUtc(), DateTime.utc(2026, 3, 10, 8));
      expect(lecture.end!.toUtc(), DateTime.utc(2026, 3, 10, 9, 30));
      final holiday = shown.last;
      expect(holiday.allDay, isTrue);
      expect((holiday.start, holiday.end), (DateTime(2026, 4, 1), DateTime(2026, 4, 3))); // the end is the last day
      expect(holiday.occursOn(DateTime(2026, 4, 3)), isTrue);
      expect(holiday.occursOn(DateTime(2026, 4, 4)), isFalse);
      expect(holiday.calendarKey, 'ics:t');
    });

    test('a single all-day event has no end, a duration is understood, junk is skipped', () {
      final cal = parseIcs(ics(
        '${event('SUMMARY:One day\nDTSTART;VALUE=DATE:20260105')}${event('SUMMARY:Two hours\nDTSTART:20260105T100000Z\nDURATION:PT2H', uid: 'u2')}${event('SUMMARY:No start', uid: 'u3')}${event('SUMMARY:Bad\nDTSTART:soon', uid: 'u4')}BEGIN:VEVENT\nUID:u5\nSUMMARY:With alarm\nDTSTART:20260106T100000Z\nBEGIN:VALARM\nSUMMARY:ring\nEND:VALARM\nEND:VEVENT\n',
      ));
      final shown = expandIcs(cal, DateTime(2026, 1, 1), DateTime(2026, 2, 1), calendarName: 'c', key: 'k');
      expect(shown.map((e) => e.title), ['One day', 'Two hours', 'With alarm']);
      expect(shown[0].end, isNull);
      expect(shown[1].end!.difference(shown[1].start), const Duration(hours: 2));
    });

    test('only what touches the wanted time is returned', () {
      final text = ics(event('SUMMARY:Old\nDTSTART:20200101T100000Z\nDTEND:20200101T110000Z'));
      expect(expand(text, '2026-01-01', '2026-02-01'), isEmpty);
      expect(expand(text, '2020-01-01', '2020-01-02'), hasLength(1));
    });
  });

  group('repeating events', () {
    test('weekly on some days, with a count and an exception', () {
      final text = ics(event('''
SUMMARY:Gym
DTSTART:20260302T180000Z
DTEND:20260302T190000Z
RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=5
EXDATE:20260304T180000Z'''));
      // Mon 2, (Wed 4 removed), Mon 9, Wed 11, Mon 16 -> five including the removed one
      expect(days(expand(text, '2026-03-01', '2026-04-30')), ['2026-03-02', '2026-03-09', '2026-03-11', '2026-03-16']);
      expect(expand(text, '2026-03-01', '2026-04-30').every((e) => e.repeats), isTrue);
    });

    test('a changed and a cancelled occurrence', () {
      final text = ics(event('''
SUMMARY:Seminar
DTSTART:20260303T090000Z
DTEND:20260303T100000Z
RRULE:FREQ=WEEKLY;COUNT=4''') +
          event('''
SUMMARY:Seminar (moved)
RECURRENCE-ID:20260310T090000Z
DTSTART:20260310T140000Z
DTEND:20260310T150000Z''') +
          event('''
SUMMARY:Seminar
RECURRENCE-ID:20260317T090000Z
DTSTART:20260317T090000Z
DTEND:20260317T100000Z
STATUS:CANCELLED'''));
      final shown = expand(text, '2026-03-01', '2026-04-30');
      expect(shown.map((e) => '${e.title}@${e.start.toUtc().day}T${e.start.toUtc().hour}'), ['Seminar@3T9', 'Seminar (moved)@10T14', 'Seminar@24T9']);
    });

    test('daily every second day until a date', () {
      final text = ics(event('SUMMARY:Pills\nDTSTART;VALUE=DATE:20260301\nRRULE:FREQ=DAILY;INTERVAL=2;UNTIL=20260309'));
      expect(days(expand(text, '2026-03-01', '2026-04-01')), ['2026-03-01', '2026-03-03', '2026-03-05', '2026-03-07', '2026-03-09']);
    });

    test('monthly: a day number that some months lack, the n-th and the last weekday', () {
      final text = ics(event('SUMMARY:End\nDTSTART;VALUE=DATE:20260131\nRRULE:FREQ=MONTHLY;BYMONTHDAY=31;COUNT=4') +
          event('SUMMARY:Board\nDTSTART:20260113T150000Z\nDTEND:20260113T160000Z\nRRULE:FREQ=MONTHLY;BYDAY=2TU;COUNT=3', uid: 'b') +
          event('SUMMARY:Payday\nDTSTART;VALUE=DATE:20260130\nRRULE:FREQ=MONTHLY;BYDAY=-1FR;COUNT=3', uid: 'p'));
      final shown = expand(text, '2026-01-01', '2026-07-01');
      List<String> of(String title) => days(shown.where((e) => e.title == title).toList());
      expect(of('End'), ['2026-01-31', '2026-03-31', '2026-05-31']); // Feb and Apr have no 31st; the fourth (July) is out of range
      expect(of('Board'), ['2026-01-13', '2026-02-10', '2026-03-10']);
      expect(of('Payday'), ['2026-01-30', '2026-02-27', '2026-03-27']);
    });

    test('monthly on the last working day (BYSETPOS) and yearly birthdays', () {
      final text = ics(event('SUMMARY:Report\nDTSTART;VALUE=DATE:20260130\nRRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3') +
          event('SUMMARY:Birthday\nDTSTART;VALUE=DATE:19900520\nRRULE:FREQ=YEARLY', uid: 'b'));
      final shown = expand(text, '2026-01-01', '2026-12-31');
      expect(days(shown.where((e) => e.title == 'Report').toList()), ['2026-01-30', '2026-02-27', '2026-03-31']);
      expect(days(shown.where((e) => e.title == 'Birthday').toList()), ['2026-05-20']);
      expect(days(expand(text, '2027-01-01', '2027-12-31').where((e) => e.title == 'Birthday').toList()), ['2027-05-20']);
    });

    test('a weekly 10:00 in Zurich stays 10:00 when the clocks change', () {
      final text = ics(event('''
SUMMARY:Stand-up
DTSTART;TZID=Europe/Zurich:20260323T100000
DTEND;TZID=Europe/Zurich:20260323T103000
RRULE:FREQ=WEEKLY;COUNT=3'''));
      final shown = expand(text, '2026-03-01', '2026-05-01');
      // 23 March: winter time (09:00 UTC); 30 March and 6 April: summer time (08:00 UTC)
      expect(shown.map((e) => e.start.toUtc().hour), [9, 8, 8]);
      expect(shown.first.start.toUtc(), DateTime.utc(2026, 3, 23, 9));
      expect(shown.first.end!.difference(shown.first.start), const Duration(minutes: 30));
    });

    test('Outlook zone names are understood, unknown zones fall back to the local clock', () {
      final outlook = ics(event('SUMMARY:A\nDTSTART;TZID=W. Europe Standard Time:20260115T100000\nDTEND;TZID=W. Europe Standard Time:20260115T110000'));
      expect(expand(outlook, '2026-01-01', '2026-02-01').single.start.toUtc(), DateTime.utc(2026, 1, 15, 9));
      final unknown = ics(event('SUMMARY:B\nDTSTART;TZID=Mars/Olympus:20260115T100000\nDTEND;TZID=Mars/Olympus:20260115T110000'));
      expect(expand(unknown, '2026-01-01', '2026-02-01').single.start, DateTime(2026, 1, 15, 10));
      final floating = ics(event('SUMMARY:C\nDTSTART:20260115T100000\nDTEND:20260115T110000'));
      expect(expand(floating, '2026-01-01', '2026-02-01').single.start, DateTime(2026, 1, 15, 10));
    });
  });

  group('the service', () {
    late IcsCalendarService service;
    late Map<String, String> served;
    var now = DateTime(2026, 3, 1, 12);

    setUp(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('ics_calendars');
      served = {};
      now = DateTime(2026, 3, 1, 12);
      service = IcsCalendarService(db, now: () => now, fetch: (url) async {
        final text = served[url.toString()];
        if (text == null) throw Exception('404');
        return text;
      });
      await service.load();
    });

    final lecture = ics(event('SUMMARY:Lecture\nDTSTART:20260310T080000Z\nDTEND:20260310T090000Z'), header: 'X-WR-CALNAME:Uni\n');

    test('a file is imported, shown, and replaced when imported again', () async {
      final s = await service.importFile('timetable.ics', lecture);
      expect((s.name, s.eventCount, s.url), ('Uni', 1, null));
      expect(service.sources.length, 1);
      expect((await service.events(DateTime(2026, 3, 1), DateTime(2026, 4, 1))).single.title, 'Lecture');
      expect(service.calendarInfos().single.key, s.key);

      await service.importFile('other.ics', lecture.replaceAll('X-WR-CALNAME:Uni\n', ''));
      expect(service.sources.map((e) => e.name), ['Uni', 'other']); // named after the file
      await service.importFile('x.ics', lecture.replaceAll('Lecture', 'Lecture 2'));
      expect(service.sources.length, 2); // same name: replaced
      expect((await service.events(DateTime(2026, 3, 1), DateTime(2026, 4, 1))).map((e) => e.title), contains('Lecture 2'));
    });

    test('a file without events is refused and keeps nothing', () async {
      await expectLater(service.importFile('empty.ics', ics('')), throwsFormatException);
      await expectLater(service.importFile('x.ics', 'this is not a calendar'), throwsFormatException);
      expect(service.sources, isEmpty);
    });

    test('it is kept, and renamed and removed', () async {
      final s = await service.importFile('a.ics', lecture);
      await service.rename(s.id, 'My uni');
      expect(service.sources.single.name, 'My uni');
      final again = IcsCalendarService(await AppDatabase.open(path: inMemoryDatabasePath));
      expect(again.sources, isEmpty); // (another database)
      await service.remove(s.id);
      expect(service.sources, isEmpty);
      expect(await service.events(DateTime(2026, 3, 1), DateTime(2026, 4, 1)), isEmpty);
    });

    test('a link is followed, read again when old, and bad addresses are refused', () async {
      served['https://example.org/cal.ics'] = lecture;
      final s = await service.addLink('webcal://example.org/cal.ics');
      expect(s.url, 'https://example.org/cal.ics');
      expect(service.sources.length, 1);
      await service.addLink('https://example.org/cal.ics');
      expect(service.sources.length, 1); // the same link

      served['https://example.org/cal.ics'] = lecture.replaceAll('Lecture', 'Lecture (new)');
      await service.refreshStale();
      expect((await service.events(DateTime(2026, 3, 1), DateTime(2026, 4, 1))).single.title, 'Lecture'); // still fresh
      now = now.add(const Duration(hours: 7));
      await service.refreshStale();
      expect((await service.events(DateTime(2026, 3, 1), DateTime(2026, 4, 1))).single.title, 'Lecture (new)');

      // a link that stops working keeps the last copy
      served.clear();
      now = now.add(const Duration(hours: 7));
      await service.refreshStale(); // quiet
      await expectLater(service.refresh(s.id), throwsA(anything));
      expect(service.sources.single.eventCount, 1);

      await expectLater(service.addLink('ftp://example.org/x.ics'), throwsFormatException);
      await expectLater(service.addLink('not a link'), throwsFormatException);
      await expectLater(service.addLink('https://example.org/missing.ics'), throwsA(anything));
    });
  });

  testWidgets('settings: import a file, see it listed, remove it', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = await tester.runAsync(() => AppDatabase.open(path: inMemoryDatabasePath));
    await tester.runAsync(() => db!.delete('ics_calendars'));
    final service = IcsCalendarService(db!);
    var picked = 0;
    await tester.pumpWidget(MaterialApp(
      home: CalDavSettingsScreen(
        ics: service,
        pickIcsFile: () async => ++picked == 1
            ? (name: 'plan.ics', content: ics(event('SUMMARY:Lecture\nDTSTART:20260310T080000Z')))
            : (name: 'bad.ics', content: 'nothing here'),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('ics-import')), 300, scrollable: find.byType(Scrollable).first);

    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
    }

    await tester.tap(find.byKey(const ValueKey('ics-import')));
    await settle();
    expect(find.text('plan'), findsOneWidget); // named after the file
    expect(find.textContaining('1 event'), findsWidgets);
    expect(find.textContaining('Imported 1 event into "plan"'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ics-import')));
    await settle();
    expect(find.textContaining('no events'), findsOneWidget); // refused, with the reason
    expect(service.sources.length, 1);

    await tester.tap(find.byKey(ValueKey('ics-remove-${service.sources.single.id}')));
    await settle();
    expect(find.text('plan'), findsNothing);
    expect(service.sources, isEmpty);
  });
}
