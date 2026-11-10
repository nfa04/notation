import 'package:flutter_test/flutter_test.dart';
import 'package:notes/sync/ics.dart';

List<({String title, DateTime start, DateTime? end})> expand(String body, DateTime from, DateTime to) {
  final cal = parseIcs('BEGIN:VCALENDAR\n$body\nEND:VCALENDAR');
  return [for (final e in expandIcs(cal, from, to, calendarName: 'c', key: 'k')) (title: e.title, start: e.start.toUtc(), end: e.end?.toUtc())];
}

void main() {
  final jan = DateTime(2026, 1, 1), feb = DateTime(2026, 2, 1);

  test('a cancelled repeating event shows nothing, and nor do the changes made to its occurrences', () {
    final r = expand('''BEGIN:VEVENT
UID:a
SUMMARY:Gone
DTSTART:20260105T100000Z
DTEND:20260105T110000Z
RRULE:FREQ=WEEKLY;COUNT=3
STATUS:CANCELLED
END:VEVENT
BEGIN:VEVENT
UID:a
SUMMARY:Gone, moved
RECURRENCE-ID:20260112T100000Z
DTSTART:20260113T100000Z
DTEND:20260113T110000Z
END:VEVENT''', jan, feb);
    expect(r, isEmpty);
  });

  test('an occurrence moved into the shown time from outside it is shown', () {
    const series = '''BEGIN:VEVENT
UID:b
SUMMARY:Weekly
DTSTART:20260105T100000Z
DTEND:20260105T110000Z
RRULE:FREQ=WEEKLY
END:VEVENT
BEGIN:VEVENT
UID:b
SUMMARY:Moved early
RECURRENCE-ID:20260126T100000Z
DTSTART:20260119T150000Z
DTEND:20260119T160000Z
END:VEVENT''';
    final r = expand(series, DateTime.utc(2026, 1, 19), DateTime.utc(2026, 1, 20));
    expect(r.map((e) => e.start), contains(DateTime.utc(2026, 1, 19, 15)));
    // once, also when the original is in the window too
    final all = expand(series, jan, DateTime(2026, 3, 1));
    expect(all.where((e) => e.title == 'Moved early'), hasLength(1));
    expect(all.where((e) => e.start == DateTime.utc(2026, 1, 26, 10)), isEmpty);
  });

  test('an exception date in UTC takes out the occurrence of an event with a zone', () {
    final r = expand('''BEGIN:VEVENT
UID:c
SUMMARY:Zurich
DTSTART;TZID=Europe/Zurich:20260105T100000
DTEND;TZID=Europe/Zurich:20260105T110000
RRULE:FREQ=WEEKLY;COUNT=3
EXDATE:20260112T090000Z
END:VEVENT''', jan, feb);
    expect(r.map((e) => e.start), [DateTime.utc(2026, 1, 5, 9), DateTime.utc(2026, 1, 19, 9)]);
  });

  test('an end in another zone than the start is the moment it is', () {
    final r = expand('''BEGIN:VEVENT
UID:d
SUMMARY:Flight
DTSTART;TZID=Europe/Zurich:20260105T100000
DTEND;TZID=America/New_York:20260105T130000
END:VEVENT''', jan, feb);
    expect(r.single.start, DateTime.utc(2026, 1, 5, 9));
    expect(r.single.end, DateTime.utc(2026, 1, 5, 18)); // 13:00 in New York
  });

  test('an UNTIL with no zone is in the zone of the event', () {
    final r = expand('''BEGIN:VEVENT
UID:i
SUMMARY:Daily
DTSTART;TZID=Europe/Zurich:20260105T230000
DTEND;TZID=Europe/Zurich:20260105T233000
RRULE:FREQ=DAILY;UNTIL=20260107T225959
END:VEVENT''', jan, feb);
    expect(r, hasLength(2)); // the 7th at 23:00 is after the end
  });
}
