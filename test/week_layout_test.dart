import 'package:flutter_test/flutter_test.dart';
import 'package:notes/screens/week_layout.dart';
import 'package:notes/sync/caldav_remote.dart';

DayEvent timed(String title, DateTime start, DateTime? end) =>
    DayEvent(title: title, start: start, end: end, allDay: false, calendarName: 'c');

void main() {
  final day = DateTime(2026, 11, 5);
  DateTime at(int h, [int m = 0]) => DateTime(2026, 11, 5, h, m);

  Map<String, PlacedEvent> layout(List<DayEvent> events, [DateTime? d]) =>
      {for (final p in layoutDay(events, d ?? day)) p.event.title: p};

  test('a single event fills the width', () {
    final p = layout([timed('a', at(9), at(10, 30))])['a']!;
    expect((p.startMinute, p.endMinute, p.lane, p.lanes), (540, 630, 0, 1));
  });

  test('overlapping events share the width, later ones reuse free columns', () {
    final l = layout([
      timed('a', at(9), at(11)),
      timed('b', at(10), at(12)),
      timed('c', at(11), at(12)), // fits where a was
    ]);
    expect((l['a']!.lane, l['a']!.lanes), (0, 2));
    expect((l['b']!.lane, l['b']!.lanes), (1, 2));
    expect((l['c']!.lane, l['c']!.lanes), (0, 2));
  });

  test('events one after the other do not narrow each other', () {
    final l = layout([timed('a', at(9), at(10)), timed('b', at(10), at(11))]);
    expect([l['a']!.lanes, l['b']!.lanes], [1, 1]);
  });

  test('all-day events are not in the grid', () {
    final all = DayEvent(title: 'x', start: day, allDay: true, calendarName: 'c');
    expect(layoutDay([all], day), isEmpty);
  });

  test('short events and events without an end are given a readable height', () {
    final l = layout([timed('short', at(9), at(9, 5)), timed('open', at(13), null)]);
    expect(l['short']!.endMinute - l['short']!.startMinute, minEventMinutes);
    expect(l['open']!.endMinute - l['open']!.startMinute, 60);
  });

  test('an event across midnight is cut to each day', () {
    final night = timed('night', at(22), DateTime(2026, 11, 6, 2));
    expect([layout([night])['night']!.startMinute, layout([night])['night']!.endMinute], [1320, 1440]);
    final next = layout([night], DateTime(2026, 11, 6))['night']!;
    expect([next.startMinute, next.endMinute], [0, 120]);
    expect(layout([night], DateTime(2026, 11, 7)), isEmpty);
  });

  test('an event ending exactly at midnight is not on the next day', () {
    final e = timed('late', at(20), DateTime(2026, 11, 6));
    expect(layout([e], DateTime(2026, 11, 6)), isEmpty);
  });

  test('events of other days are ignored', () {
    expect(layout([timed('x', DateTime(2026, 11, 8, 9), DateTime(2026, 11, 8, 10))]), isEmpty);
  });
}
