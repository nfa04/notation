import 'package:flutter_test/flutter_test.dart';
import 'package:notes/sync/caldav_remote.dart';
import 'package:notes/sync/ics.dart';
import 'package:notes/sync/ics_write.dart';

const _file = '''BEGIN:VCALENDAR\r
VERSION:2.0\r
PRODID:-//Someone Else//EN\r
BEGIN:VTIMEZONE\r
TZID:Europe/Zurich\r
END:VTIMEZONE\r
BEGIN:VEVENT\r
UID:abc\r
DTSTAMP:20261101T000000Z\r
DTSTART;TZID=Europe/Zurich:20261102T080000\r
DTEND;TZID=Europe/Zurich:20261102T090000\r
SUMMARY:Standup\r
LOCATION:Room 1\r
RRULE:FREQ=WEEKLY;BYDAY=MO\r
ORGANIZER:mailto:boss@example.org\r
ATTENDEE;PARTSTAT=ACCEPTED:mailto:ann@example.org\r
ATTENDEE:mailto:bob@example.org\r
X-CUSTOM:keep me\r
BEGIN:VALARM\r
ACTION:DISPLAY\r
TRIGGER:-PT15M\r
DESCRIPTION:x\r
END:VALARM\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:abc\r
RECURRENCE-ID;TZID=Europe/Zurich:20261109T080000\r
DTSTART;TZID=Europe/Zurich:20261110T080000\r
DTEND;TZID=Europe/Zurich:20261110T090000\r
SUMMARY:Standup (moved)\r
END:VEVENT\r
END:VCALENDAR\r
''';

DayEvent get _shown => DayEvent(
      title: 'Standup',
      start: DateTime(2026, 11, 2, 8),
      end: DateTime(2026, 11, 2, 9),
      allDay: false,
      calendarName: 'Work',
    );

void main() {
  test('a new event is written with everything the dialog has, and read back the same', () {
    final text = buildEventIcs(
      NewEvent(
        title: 'Party, with; commas',
        start: DateTime(2026, 12, 5, 19),
        end: DateTime(2026, 12, 5, 23),
        description: 'Bring cake\nand drinks',
        location: 'Home',
        url: 'https://example.org/p',
        alarms: const [10, 1440],
        attendees: const ['ann@example.org'],
        rrule: 'FREQ=YEARLY',
      ),
      uid: 'u1',
    );
    final back = parseIcs(text).events.single;
    expect(back.uid, 'u1');
    expect(back.summary, 'Party, with; commas');
    expect(back.description, 'Bring cake\nand drinks');
    expect(back.location, 'Home');
    expect(back.url, 'https://example.org/p');
    expect(back.alarms, [10, 1440]);
    expect(back.attendees, ['ann@example.org']);
    expect(back.rruleText, 'FREQ=YEARLY');
    expect(text.split('\r\n').every((l) => l.length <= 75), isTrue);
  });

  test('a long line is folded and unfolds to the same text', () {
    final long = 'x' * 200;
    final text = buildEventIcs(NewEvent(title: long, start: DateTime(2026, 12, 5, 9)), uid: 'u');
    expect(parseIcs(text).events.single.summary, long);
    expect(text.split('\r\n').every((l) => l.length <= 75), isTrue);
  });

  test('an all-day event is written as dates, the end the day after its last', () {
    final text = buildEventIcs(NewEvent(title: 'Trip', start: DateTime(2026, 12, 5), end: DateTime(2026, 12, 7), allDay: true), uid: 'u');
    expect(text, contains('DTSTART;VALUE=DATE:20261205'));
    expect(text, contains('DTEND;VALUE=DATE:20261208'));
  });

  test('a change keeps the rest of the file: organizer, answers, custom properties, other events, the zone', () {
    final out = patchEventIcs(
      _file,
      NewEvent(title: 'Daily standup', start: DateTime(2026, 11, 2, 8, 30), end: DateTime(2026, 11, 2, 9, 30), location: 'Room 2', keepNotes: true),
      old: _shown,
    );
    expect(out, contains('SUMMARY:Daily standup'));
    expect(out, contains('LOCATION:Room 2'));
    expect(out, contains('DTSTART;TZID=Europe/Zurich:20261102T083000'));
    expect(out, contains('DTEND;TZID=Europe/Zurich:20261102T093000'));
    expect(out, contains('RRULE:FREQ=WEEKLY;BYDAY=MO'));
    expect(out, contains('ORGANIZER:mailto:boss@example.org'));
    expect(out, contains('ATTENDEE;PARTSTAT=ACCEPTED:mailto:ann@example.org'));
    expect(out, contains('X-CUSTOM:keep me'));
    expect(out, contains('TRIGGER:-PT15M'));
    expect(out, contains('BEGIN:VTIMEZONE'));
    expect(out, contains('SUMMARY:Standup (moved)'));
    expect(out, contains('SEQUENCE:1'));
    expect(RegExp('BEGIN:VEVENT').allMatches(out).length, 2);
    expect(parseIcs(out).events.first.alarms, [15]);
  });

  test('alarms, attendees, link and repeat are replaced only when the dialog says so', () {
    final out = patchEventIcs(
      _file,
      NewEvent(title: 'Standup', start: _shown.start, end: _shown.end, keepNotes: true, alarms: const [5], attendees: const ['ann@example.org', 'cy@example.org'], url: 'https://x.org', rrule: ''),
      old: _shown,
    );
    final e = parseIcs(out).events.first;
    expect(e.alarms, [5]);
    expect(e.attendees, ['ann@example.org', 'cy@example.org']);
    expect(out, contains('ATTENDEE;PARTSTAT=ACCEPTED:mailto:ann@example.org')); // keeps the answer
    expect(out, isNot(contains('bob@example.org')));
    expect(e.url, 'https://x.org');
    expect(e.rruleText, isNull);
    expect(out, contains('LOCATION:Room 1')); // not asked: stays
    expect(out, contains('DTSTART;TZID=Europe/Zurich:20261102T080000')); // times unchanged: the lines are not touched
  });

  test('moving one shown occurrence of a series moves the series by as much', () {
    final shownLater = DayEvent(title: 'Standup', start: DateTime(2026, 11, 16, 8), end: DateTime(2026, 11, 16, 9), allDay: false, calendarName: 'Work');
    final out = patchEventIcs(_file, NewEvent(title: 'Standup', start: DateTime(2026, 11, 16, 10), end: DateTime(2026, 11, 16, 11), keepNotes: true), old: shownLater);
    expect(out, contains('DTSTART;TZID=Europe/Zurich:20261102T100000'));
    expect(out, contains('DTEND;TZID=Europe/Zurich:20261102T110000'));
  });

  test('notes are replaced, or cleared, unless the change leaves them alone', () {
    final withNotes = _file.replaceFirst('SUMMARY:Standup', 'DESCRIPTION:old notes\r\nSUMMARY:Standup');
    expect(patchEventIcs(withNotes, NewEvent(title: 'Standup', start: _shown.start, end: _shown.end, keepNotes: true), old: _shown), contains('DESCRIPTION:old notes'));
    expect(patchEventIcs(withNotes, NewEvent(title: 'Standup', start: _shown.start, end: _shown.end, description: 'new'), old: _shown), contains('DESCRIPTION:new'));
    expect(patchEventIcs(withNotes, NewEvent(title: 'Standup', start: _shown.start, end: _shown.end), old: _shown), isNot(contains('DESCRIPTION:old')));
  });
}
