import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/reminders/reminder.dart';

/// The jumps that find the next and the previous time of a repeating reminder are checked against counting one by one.
void main() {
  final repeats = [Repeat.daily, Repeat.weekly, Repeat.monthly, Repeat.yearly];

  /// All occurrences of [start] from the first to the last one that is not after [limit], by counting.
  List<DateTime> allUpTo(DateTime start, Repeat repeat, DateTime limit) {
    final out = <DateTime>[];
    for (var n = 0; n < 5000; n++) {
      final o = occurrence(start, repeat, n);
      if (o.isAfter(limit)) break;
      out.add(o);
    }
    return out;
  }

  DateTime randomStart(Random rnd) => DateTime(2020 + rnd.nextInt(8), 1 + rnd.nextInt(12), 1 + rnd.nextInt(31), rnd.nextInt(24), rnd.nextInt(60));

  test('the next time at or after, the next after and the last at or before agree with counting', () {
    final rnd = Random(2026);
    for (var round = 0; round < 800; round++) {
      final repeat = repeats[rnd.nextInt(repeats.length)];
      final start = randomStart(rnd);
      final t = start.add(Duration(minutes: rnd.nextInt(60 * 24 * 200) - 60 * 24 * 3, seconds: rnd.nextInt(60)));
      final upTo = allUpTo(start, repeat, t.add(const Duration(days: 400)));
      final atOrAfter = upTo.where((o) => !o.isBefore(t)).firstOrNull;
      final after = upTo.where((o) => o.isAfter(t)).firstOrNull;
      final atOrBefore = upTo.where((o) => !o.isAfter(t)).lastOrNull;
      final why = '$repeat from $start, t=$t';
      expect(occurrenceAtOrAfter(start, repeat, t), atOrAfter, reason: 'at or after: $why');
      expect(occurrenceAfter(start, repeat, t), after, reason: 'after: $why');
      expect(occurrenceAtOrBefore(start, repeat, t), atOrBefore, reason: 'at or before: $why');
    }
  });

  test('a monthly reminder on the 31st is the last day of the short months and comes back to the 31st', () {
    final start = DateTime(2026, 1, 31, 9);
    final days = [for (var n = 0; n < 6; n++) occurrence(start, Repeat.monthly, n).day];
    expect(days, [31, 28, 31, 30, 31, 30]);
  });

  test('a yearly reminder on the 29th of February is the 28th in the years without one', () {
    final start = DateTime(2024, 2, 29, 8);
    expect([for (var n = 0; n < 5; n++) occurrence(start, Repeat.yearly, n)], [
      DateTime(2024, 2, 29, 8),
      DateTime(2025, 2, 28, 8),
      DateTime(2026, 2, 28, 8),
      DateTime(2027, 2, 28, 8),
      DateTime(2028, 2, 29, 8),
    ]);
  });

  test('a one-time reminder has its time only, until it has passed', () {
    final at = DateTime(2026, 5, 1, 10);
    expect(occurrenceAtOrAfter(at, Repeat.none, DateTime(2026, 5, 1, 9)), at);
    expect(occurrenceAtOrAfter(at, Repeat.none, at), at);
    expect(occurrenceAtOrAfter(at, Repeat.none, DateTime(2026, 5, 1, 10, 1)), isNull);
    expect(occurrenceAfter(at, Repeat.none, at), isNull);
    expect(occurrenceAtOrBefore(at, Repeat.none, DateTime(2026, 5, 1, 9)), isNull);
    expect(occurrenceAtOrBefore(at, Repeat.none, DateTime(2026, 5, 2)), at);
  });

  test('before the start nothing has come, and the first one is the start', () {
    final start = DateTime(2026, 5, 1, 10);
    for (final r in repeats) {
      expect(occurrenceAtOrBefore(start, r, DateTime(2026, 4, 30)), isNull, reason: '$r');
      expect(occurrenceAtOrAfter(start, r, DateTime(2026, 4, 30)), start, reason: '$r');
      expect(occurrenceAfter(start, r, DateTime(2026, 4, 30)), start, reason: '$r');
    }
  });
}
