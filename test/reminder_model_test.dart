import 'package:flutter_test/flutter_test.dart';
import 'package:notes/reminders/reminder.dart';

void main() {
  group('occurrences', () {
    test('daily and weekly count calendar days, across a month end', () {
      final start = DateTime(2026, 1, 30, 9, 30);
      expect(occurrence(start, Repeat.daily, 3), DateTime(2026, 2, 2, 9, 30));
      expect(occurrence(start, Repeat.weekly, 1), DateTime(2026, 2, 6, 9, 30));
    });

    test('a month without the day takes its last day, and later months are not moved by it', () {
      final start = DateTime(2026, 1, 31, 8);
      expect(occurrence(start, Repeat.monthly, 1), DateTime(2026, 2, 28, 8));
      expect(occurrence(start, Repeat.monthly, 2), DateTime(2026, 3, 31, 8));
      expect(occurrence(start, Repeat.monthly, 3), DateTime(2026, 4, 30, 8));
      expect(occurrence(start, Repeat.monthly, 12), DateTime(2027, 1, 31, 8));
    });

    test('a 29th of February comes on the 28th in other years', () {
      final start = DateTime(2024, 2, 29, 12);
      expect(occurrence(start, Repeat.yearly, 1), DateTime(2025, 2, 28, 12));
      expect(occurrence(start, Repeat.yearly, 4), DateTime(2028, 2, 29, 12));
    });

    test('the occurrence after or at a time, for each repeat', () {
      final start = DateTime(2026, 3, 1, 9);
      expect(occurrenceAtOrAfter(start, Repeat.none, DateTime(2026, 2, 1)), start);
      expect(occurrenceAtOrAfter(start, Repeat.none, DateTime(2026, 3, 2)), isNull);
      expect(occurrenceAtOrAfter(start, Repeat.daily, DateTime(2026, 3, 5, 9)), DateTime(2026, 3, 5, 9));
      expect(occurrenceAfter(start, Repeat.daily, DateTime(2026, 3, 5, 9)), DateTime(2026, 3, 6, 9));
      expect(occurrenceAfter(start, Repeat.weekly, DateTime(2026, 3, 9, 8)), DateTime(2026, 3, 8, 9) .add(const Duration(days: 7)));
      expect(occurrenceAfter(start, Repeat.monthly, DateTime(2026, 8, 1, 9, 1)), DateTime(2026, 9, 1, 9));
      expect(occurrenceAfter(start, Repeat.yearly, DateTime(2030, 3, 1, 9)), DateTime(2031, 3, 1, 9));
      expect(occurrenceAtOrAfter(start, Repeat.daily, DateTime(2020)), start); // before the start
    });

    test('the last occurrence at or before a time', () {
      final start = DateTime(2026, 3, 1, 9);
      expect(occurrenceAtOrBefore(start, Repeat.daily, DateTime(2026, 3, 1, 8)), isNull);
      expect(occurrenceAtOrBefore(start, Repeat.daily, DateTime(2026, 3, 10, 12)), DateTime(2026, 3, 10, 9));
      expect(occurrenceAtOrBefore(start, Repeat.daily, DateTime(2026, 3, 10, 8)), DateTime(2026, 3, 9, 9));
      expect(occurrenceAtOrBefore(start, Repeat.weekly, DateTime(2026, 4, 1)), DateTime(2026, 3, 29, 9));
      expect(occurrenceAtOrBefore(start, Repeat.none, DateTime(2027)), start);
      expect(occurrenceAtOrBefore(start, Repeat.yearly, DateTime(2036, 2, 1)), DateTime(2035, 3, 1, 9));
    });
  });

  group('Reminder', () {
    Reminder r(Repeat repeat, {DateTime? firedTo}) =>
        Reminder(id: 'a', kind: ReminderKind.custom, title: 'Call', at: DateTime(2026, 3, 1, 9), repeat: repeat, firedTo: firedTo);

    test('a one-time reminder is pending until it was announced', () {
      expect(r(Repeat.none).pending, DateTime(2026, 3, 1, 9));
      expect(r(Repeat.none, firedTo: DateTime(2026, 3, 1, 9)).pending, isNull);
    });

    test('a repeating one is pending at the occurrence after the one announced', () {
      expect(r(Repeat.daily, firedTo: DateTime(2026, 3, 4, 9)).pending, DateTime(2026, 3, 5, 9));
    });

    test('the next few occurrences', () {
      final list = r(Repeat.weekly).occurrencesFrom(DateTime(2026, 3, 10), count: 3);
      expect(list, [DateTime(2026, 3, 15, 9), DateTime(2026, 3, 22, 9), DateTime(2026, 3, 29, 9)]);
      expect(r(Repeat.daily).occurrencesFrom(DateTime(2026, 3, 1), until: DateTime(2026, 3, 3, 12)).length, 3);
      expect(r(Repeat.none).occurrencesFrom(DateTime(2026, 3, 2)), isEmpty);
      expect(r(Repeat.none).occurrencesFrom(DateTime(2026, 2, 2)), [DateTime(2026, 3, 1, 9)]);
    });
  });
}
