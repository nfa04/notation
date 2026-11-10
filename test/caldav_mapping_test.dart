import 'package:caldav/caldav.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/sync/caldav_remote.dart';

CalendarTodo todo({DateTime? due, bool allDay = false}) =>
    CalendarTodo(uid: 'u', calendarId: 'c', summary: 's', due: due, isAllDay: allDay);

DayEvent event(DateTime start, {DateTime? end, bool allDay = false}) =>
    DayEvent(title: 't', start: start, end: end, allDay: allDay, calendarName: 'c');

void main() {
  group('due day of a to-do', () {
    test('no due date', () => expect(dueDayOf(todo()), isNull));

    test('an all-day due date is the same date in every time zone', () {
      // parsed as UTC midnight: must not slip to the previous day west of UTC
      expect(dueDayOf(todo(due: DateTime.utc(2026, 11, 5), allDay: true)), DateTime(2026, 11, 5));
    });

    test('a timed due date is the local day', () {
      final due = DateTime.utc(2026, 11, 5, 23, 30);
      final local = due.toLocal();
      expect(dueDayOf(todo(due: due)), DateTime(local.year, local.month, local.day));
    });
  });

  group('events on a day', () {
    test('a timed event is on its own day only', () {
      final e = event(DateTime(2026, 11, 5, 14), end: DateTime(2026, 11, 5, 15));
      expect(e.occursOn(DateTime(2026, 11, 5)), isTrue);
      expect(e.occursOn(DateTime(2026, 11, 4)), isFalse);
      expect(e.occursOn(DateTime(2026, 11, 6)), isFalse);
    });

    test('an all-day event spans its inclusive last day', () {
      final e = event(DateTime(2026, 11, 5), end: DateTime(2026, 11, 7), allDay: true);
      for (final d in [5, 6, 7]) {
        expect(e.occursOn(DateTime(2026, 11, d)), isTrue, reason: 'day $d');
      }
      expect(e.occursOn(DateTime(2026, 11, 8)), isFalse);
    });

    test('a single-day all-day event has no end', () {
      final e = event(DateTime(2026, 11, 5), allDay: true);
      expect(e.occursOn(DateTime(2026, 11, 5)), isTrue);
      expect(e.occursOn(DateTime(2026, 11, 6)), isFalse);
    });

    test('an event ending at midnight does not spill into the next day', () {
      final e = event(DateTime(2026, 11, 5, 20), end: DateTime(2026, 11, 6));
      expect(e.occursOn(DateTime(2026, 11, 5)), isTrue);
      expect(e.occursOn(DateTime(2026, 11, 6)), isFalse);
    });

    test('a night across midnight is on both days', () {
      final e = event(DateTime(2026, 11, 5, 22), end: DateTime(2026, 11, 6, 2));
      expect(e.occursOn(DateTime(2026, 11, 5)), isTrue);
      expect(e.occursOn(DateTime(2026, 11, 6)), isTrue);
    });
  });
}
