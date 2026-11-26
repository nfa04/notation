import 'package:flutter_test/flutter_test.dart';
import 'package:notes/sync/repeat_rule.dart';

void main() {
  test('rules the dialog writes are read back as the same rule', () {
    for (final text in ['FREQ=DAILY', 'FREQ=WEEKLY;BYDAY=MO,WE', 'FREQ=MONTHLY;INTERVAL=2', 'FREQ=YEARLY;COUNT=5', 'FREQ=WEEKLY;INTERVAL=2;BYDAY=FR;UNTIL=20270101']) {
      expect(RepeatRule.parse(text)!.toRrule(allDay: true), text);
    }
  });

  test('a rule with more in it than the dialog knows is not taken apart', () {
    for (final text in ['FREQ=MONTHLY;BYDAY=3FR', 'FREQ=MONTHLY;BYMONTHDAY=1,15', 'FREQ=YEARLY;BYMONTH=3', 'FREQ=HOURLY', 'FREQ=WEEKLY;UNTIL=20270101;COUNT=3', '', 'nonsense']) {
      expect(RepeatRule.parse(text), isNull, reason: text);
    }
  });

  test('an end day of a timed event is the end of that day', () {
    final rule = RepeatRule(frequency: RepeatFrequency.daily, end: RepeatEnd.onDay, until: DateTime(2027, 1, 10));
    final text = rule.toRrule();
    expect(text, startsWith('FREQ=DAILY;UNTIL='));
    expect(text, endsWith('Z'));
    final back = RepeatRule.parse(text)!;
    // (the day it ends on is the day it was given, or the one before in a zone east of Greenwich where the end of day is the day before in UTC)
    expect(back.until!.difference(DateTime(2027, 1, 10)).inDays.abs(), lessThanOrEqualTo(1));
  });
}
