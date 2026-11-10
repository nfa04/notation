import 'package:flutter_test/flutter_test.dart';
import 'package:notes/sync/caldav_remote.dart' show DayEvent;
import 'package:notes/sync/ics.dart';

String ics(String events) => 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${events.trim().replaceAll('\n', '\r\n')}\r\nEND:VCALENDAR\r\n';

String event(String lines, {String uid = 'u1'}) => 'BEGIN:VEVENT\nUID:$uid\n${lines.trim()}\nEND:VEVENT\n';

List<DayEvent> expand(String text, String from, String to) => expandIcs(parseIcs(text), DateTime.parse(from), DateTime.parse(to), calendarName: 'Cal', key: 'ics:t');

List<String> days(List<DayEvent> events) =>
    [for (final e in events) '${e.start.year}-${e.start.month.toString().padLeft(2, '0')}-${e.start.day.toString().padLeft(2, '0')}'];

void main() {
  group('weekly rules, as RFC 5545 gives them', () {
    test('every other week on Monday and Friday, from a Wednesday: the start itself is not one of them', () {
      final text = ics(event('SUMMARY:Gym\nDTSTART;VALUE=DATE:20260304\nRRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,FR'));
      expect(days(expand(text, '2026-03-01', '2026-04-06')), ['2026-03-06', '2026-03-16', '2026-03-20', '2026-03-30', '2026-04-03']);
    });

    test('the week starts on Monday: Tuesday and the Sunday that ends the week, every other week (RFC example, WKST=MO)', () {
      final text = ics(event('SUMMARY:A\nDTSTART;VALUE=DATE:19970805\nRRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4;WKST=MO;BYDAY=TU,SU'));
      expect(days(expand(text, '1997-08-01', '1997-10-01')), ['1997-08-05', '1997-08-10', '1997-08-19', '1997-08-24']);
    });

    test('the week starts on Sunday: the Sunday opens the week, so the same rule gives other days (RFC example, WKST=SU)', () {
      final text = ics(event('SUMMARY:A\nDTSTART;VALUE=DATE:19970805\nRRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4;WKST=SU;BYDAY=TU,SU'));
      expect(days(expand(text, '1997-08-01', '1997-10-01')), ['1997-08-05', '1997-08-17', '1997-08-19', '1997-08-31']);
    });

    test('a rule with no day takes the weekday of the start', () {
      final text = ics(event('SUMMARY:A\nDTSTART;VALUE=DATE:20260302\nRRULE:FREQ=WEEKLY;COUNT=3'));
      expect(days(expand(text, '2026-03-01', '2026-04-30')), ['2026-03-02', '2026-03-09', '2026-03-16']);
    });
  });

  group('counting and taking out', () {
    test('an exception date still counts towards COUNT', () {
      final text = ics(event('SUMMARY:A\nDTSTART;VALUE=DATE:20260301\nRRULE:FREQ=DAILY;COUNT=4\nEXDATE;VALUE=DATE:20260302'));
      expect(days(expand(text, '2026-03-01', '2026-03-31')), ['2026-03-01', '2026-03-03', '2026-03-04']);
    });

    test('a cancelled change takes out that occurrence only', () {
      final text = ics(event('SUMMARY:Class\nDTSTART:20260302T090000Z\nDTEND:20260302T100000Z\nRRULE:FREQ=WEEKLY;COUNT=3') +
          event('SUMMARY:Class\nDTSTART:20260309T090000Z\nDTEND:20260309T100000Z\nRECURRENCE-ID:20260309T090000Z\nSTATUS:CANCELLED'));
      expect(days(expand(text, '2026-03-01', '2026-03-31')), ['2026-03-02', '2026-03-16']);
    });

    test('a change of one occurrence replaces its title and time', () {
      final text = ics(event('SUMMARY:Class\nDTSTART:20260302T090000Z\nDTEND:20260302T100000Z\nRRULE:FREQ=WEEKLY;COUNT=2') +
          event('SUMMARY:Class (room 5)\nDTSTART:20260309T140000Z\nDTEND:20260309T150000Z\nRECURRENCE-ID:20260309T090000Z'));
      final shown = expand(text, '2026-03-01', '2026-03-31');
      expect(shown.map((e) => e.title), ['Class', 'Class (room 5)']);
      expect(shown.last.start.toUtc(), DateTime.utc(2026, 3, 9, 14));
    });

    test('the same rule as many times as the range asks for gives the same days', () {
      final text = ics(event('SUMMARY:A\nDTSTART;VALUE=DATE:20260301\nRRULE:FREQ=WEEKLY;BYDAY=SU'));
      final wide = days(expand(text, '2026-03-01', '2026-06-01'));
      final pieces = [...days(expand(text, '2026-03-01', '2026-04-01')), ...days(expand(text, '2026-04-02', '2026-06-01'))];
      expect(pieces.toSet().difference(wide.toSet()), isEmpty);
    });
  });

  group('days that some years and months lack', () {
    test('the 29th of February comes only in leap years', () {
      final text = ics(event('SUMMARY:Leap\nDTSTART;VALUE=DATE:20240229\nRRULE:FREQ=YEARLY'));
      expect(expand(text, '2026-01-01', '2026-12-31'), isEmpty);
      expect(days(expand(text, '2028-01-01', '2028-12-31')), ['2028-02-29']);
    });

    test('the last day of every month', () {
      final text = ics(event('SUMMARY:End\nDTSTART;VALUE=DATE:20260131\nRRULE:FREQ=MONTHLY;BYMONTHDAY=-1;COUNT=4'));
      expect(days(expand(text, '2026-01-01', '2026-06-01')), ['2026-01-31', '2026-02-28', '2026-03-31', '2026-04-30']);
    });

    test('the last of the 29th, 30th and 31st: the last day that the month has, and no day in a February with 28', () {
      final text = ics(event('SUMMARY:A\nDTSTART;VALUE=DATE:20260129\nRRULE:FREQ=MONTHLY;BYMONTHDAY=29,30,31;BYSETPOS=-1;COUNT=3'));
      expect(days(expand(text, '2026-01-01', '2026-06-01')), ['2026-01-31', '2026-03-31', '2026-04-30']);
    });
  });

  group('rules that are wrong do no harm', () {
    for (final rule in [
      'FREQ=DAILY;INTERVAL=0',
      'FREQ=DAILY;INTERVAL=-2',
      'FREQ=DAILY;COUNT=0',
      'FREQ=WEEKLY;BYDAY=XX',
      'FREQ=MONTHLY;BYMONTHDAY=99',
      'FREQ=YEARLY;BYMONTH=13',
      'FREQ=SECONDLY',
      'FREQ=HOURLY;COUNT=5',
      'FREQ=',
      'COUNT=3',
      'FREQ=DAILY;UNTIL=nonsense',
      'freq=daily;count=2',
    ]) {
      test(rule, () {
        final text = ics(event('SUMMARY:A\nDTSTART;VALUE=DATE:20260301\nRRULE:$rule'));
        final sw = Stopwatch()..start();
        final shown = expand(text, '2026-03-01', '2026-03-31');
        expect(sw.elapsedMilliseconds, lessThan(2000));
        expect(shown.length, lessThanOrEqualTo(31));
      });
    }

    test('an event that starts in 1990 and never ends is still quick to look at', () {
      final text = ics(event('SUMMARY:Old\nDTSTART:19900101T080000Z\nDTEND:19900101T090000Z\nRRULE:FREQ=DAILY'));
      final sw = Stopwatch()..start();
      final shown = expand(text, '2026-03-01', '2026-03-08');
      expect(shown.length, 7);
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });
  });

  group('times', () {
    test('a time with no zone is the clock of the viewer', () {
      final shown = expand(ics(event('SUMMARY:A\nDTSTART:20260310T100000\nDTEND:20260310T110000')), '2026-03-01', '2026-03-31');
      expect(shown.single.start, DateTime(2026, 3, 10, 10));
    });

    test('an all-day event with the same start and end is one day, and one with a lone start too', () {
      final text = ics(event('SUMMARY:A\nDTSTART;VALUE=DATE:20260310\nDTEND;VALUE=DATE:20260310') + event('SUMMARY:B\nDTSTART;VALUE=DATE:20260311', uid: 'b'));
      final shown = expand(text, '2026-03-01', '2026-03-31');
      expect(shown.map((e) => (e.start.day, e.end)), [(10, null), (11, null)]);
    });

    test('an end before the start is taken as no length', () {
      final shown = expand(ics(event('SUMMARY:A\nDTSTART:20260310T100000Z\nDTEND:20260310T090000Z')), '2026-03-01', '2026-03-31');
      expect(shown.single.end, isNull);
    });

    test('a negative duration is no length', () {
      final shown = expand(ics(event('SUMMARY:A\nDTSTART:20260310T100000Z\nDURATION:-PT30M')), '2026-03-01', '2026-03-31');
      expect(shown.single.end, isNull);
    });

    test('an event over midnight is on both days, and one that ended before the range is not shown', () {
      final text = ics(event('SUMMARY:Night\nDTSTART:20260310T220000Z\nDTEND:20260311T020000Z'));
      final shown = expand(text, '2026-03-11', '2026-03-12');
      expect(shown, hasLength(1));
      expect(expand(text, '2026-03-12', '2026-03-13'), isEmpty);
    });

    test('a date that does not exist (month 13, February 30th, hour 25, minute 61) is no event, and not one in another year', () {
      for (final bad in ['20261301T100000Z', '20260230T100000Z', '20260310T250000Z', '20260310T106100Z', '20260431', '20260000']) {
        expect(expand(ics(event('SUMMARY:A\nDTSTART:$bad')), '2020-01-01', '2030-12-31'), isEmpty, reason: bad);
      }
      expect(expand(ics(event('SUMMARY:Leap\nDTSTART:20240229T100000Z')), '2024-01-01', '2024-12-31'), hasLength(1));
      expect(expand(ics(event('SUMMARY:Not leap\nDTSTART:20260229T100000Z')), '2020-01-01', '2030-12-31'), isEmpty);
    });

    test('an event is not shown when its date is wrong, and the ones next to it are', () {
      final shown = expand(ics(event('SUMMARY:A\nDTSTART:20261301T100000Z') + event('SUMMARY:B\nDTSTART:20260310T100000Z', uid: 'b')), '2026-01-01', '2027-12-31');
      expect(shown.map((e) => e.title), isNot(contains('A')));
      expect(shown.map((e) => e.title), contains('B'));
    });
  });

  group('reading the file', () {
    test('lines ended by a lone carriage return or a lone line feed read the same', () {
      const body = 'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:x\nSUMMARY:A\nDTSTART:20260310T100000Z\nEND:VEVENT\nEND:VCALENDAR\n';
      for (final text in [body, body.replaceAll('\n', '\r'), body.replaceAll('\n', '\r\n')]) {
        expect(parseIcs(text).events.single.summary, 'A');
      }
    });

    test('names of properties in lower case are read', () {
      final cal = parseIcs('begin:vcalendar\nbegin:vevent\nuid:x\nsummary:Small\ndtstart:20260310T100000Z\nend:vevent\nend:vcalendar\n');
      expect(cal.events.single.summary, 'Small');
    });

    test('a colon in a quoted parameter, escaped commas and semicolons, and a backslash', () {
      final cal = parseIcs(ics(event('SUMMARY;LANGUAGE="en:US":One\\, two\\; three \\\\ four\nDTSTART:20260310T100000Z')));
      expect(cal.events.single.summary, r'One, two; three \ four');
    });

    test('a file that is cut off in an event still gives the events before it', () {
      final text = 'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:a\nSUMMARY:Whole\nDTSTART:20260310T100000Z\nEND:VEVENT\nBEGIN:VEVENT\nUID:b\nSUMMARY:Cut\nDTSTA';
      expect(parseIcs(text).events.map((e) => e.summary), ['Whole']);
    });

    test('text that is no calendar gives an empty one', () {
      for (final text in ['', 'hello', '<html></html>', 'BEGIN:VCALENDAR', '\u0000\u0001']) {
        expect(parseIcs(text).events, isEmpty, reason: text);
      }
    });

    test('an alarm in an event does not end it early, and its text is not the event\'s', () {
      final text = ics('BEGIN:VEVENT\nUID:a\nSUMMARY:Real\nBEGIN:VALARM\nSUMMARY:Alarm\nEND:VALARM\nDTSTART:20260310T100000Z\nEND:VEVENT');
      final e = parseIcs(text).events.single;
      expect(e.summary, 'Real');
      expect(e.start, DateTime.utc(2026, 3, 10, 10), reason: 'the DTSTART after the alarm is still read');
    });

    test('colours are read in the forms Apple and Google write them', () {
      expect(parseIcs('BEGIN:VCALENDAR\nX-APPLE-CALENDAR-COLOR:#00ff00FF\nEND:VCALENDAR').color, '#00FF00');
      expect(parseIcs('BEGIN:VCALENDAR\nX-WR-CALCOLOR:#123ABC\nEND:VCALENDAR').color, '#123ABC');
      expect(parseIcs('BEGIN:VCALENDAR\nX-WR-CALCOLOR:red\nEND:VCALENDAR').color, isNull);
    });
  });
}
