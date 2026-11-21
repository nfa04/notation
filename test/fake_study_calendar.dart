import 'package:notes/review/study_calendar.dart';
import 'package:notes/sync/caldav_remote.dart';

/// The calendars, as a plan sees them: events of others, a calendar to write to, and a Study calendar once made.
class FakeStudyCalendar implements StudyCalendarAccess {
  final others = <DayEvent>[];
  final written = <String, (String, NewEvent)>{};
  final made = <CalendarPlace>[];
  final _calendars = [const CalendarInfo('phone:p', 'Private', null)];
  bool failWrites = false;
  var _n = 0;

  @override
  Future<List<DayEvent>> events(DateTime from, DateTime to) async => [
        ...others,
        for (final w in written.entries)
          DayEvent(title: w.value.$2.title, start: w.value.$2.start, end: w.value.$2.end, allDay: false, calendarName: 'Study', calendarKey: w.value.$1, uid: w.key),
      ];

  @override
  Future<List<CalendarInfo>> writable() async => _calendars;

  @override
  List<CalendarPlace> get places => const [CalendarPlace.phone];

  @override
  Future<CalendarInfo> makeCalendar(CalendarPlace place, String name) async {
    made.add(place);
    final c = CalendarInfo('phone:study', name, '#2E7D32');
    _calendars.add(c);
    return c;
  }

  @override
  Future<String> create(String target, NewEvent event) async {
    if (failWrites) throw StateError('The calendar is offline');
    final id = 'ev${++_n}';
    written[id] = (target, event);
    return id;
  }

  @override
  Future<void> delete(String target, String id) async => written.remove(id);
}
