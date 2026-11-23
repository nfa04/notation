import '../sync/caldav_remote.dart';
import '../sync/caldav_service.dart';
import '../sync/device_calendar_service.dart';
import '../sync/ics_service.dart';

/// Where a new calendar for study sessions can be made.
enum CalendarPlace { phone, server }

/// What the study plans need of the calendars: the events that make a time busy, the calendars a session can be written to, making a
/// calendar of its own for the sessions, and writing and taking away an event. The app's calendars in the real app, a fake in tests.
abstract class StudyCalendarAccess {
  /// The events of the calendars that are shown, from [from] to [to].
  Future<List<DayEvent>> events(DateTime from, DateTime to);

  /// The events of the calendar [target] from [from] to [to], read now (not from what was kept of an earlier reading); null when that
  /// calendar cannot be read now (it is not shown, it is gone, there is no connection or no access). What tells that a session's event
  /// was moved or deleted in the calendar app: an empty list means there are no events, never that the reading failed.
  Future<List<DayEvent>?> eventsIn(String target, DateTime from, DateTime to);

  /// The calendars a session can be written to (`phone:<id>`, or the address of a server calendar).
  Future<List<CalendarInfo>> writable();

  /// Where a calendar can be made.
  List<CalendarPlace> get places;

  /// Makes a calendar called [name] at [place] and shows it with the others.
  Future<CalendarInfo> makeCalendar(CalendarPlace place, String name);

  /// Writes [event] to the calendar [target]; returns its id there.
  Future<String> create(String target, NewEvent event);

  /// Takes the event [id] off the calendar [target] (one that is gone already is fine).
  Future<void> delete(String target, String id);
}

/// [StudyCalendarAccess] on the calendars of the app: the server's (CalDAV), the phone's and the subscribed ones (read only).
class AppStudyCalendar implements StudyCalendarAccess {
  final CalDavService? caldav;
  final DeviceCalendarService? device;
  final IcsCalendarService? ics;

  const AppStudyCalendar({this.caldav, this.device, this.ics});

  CalDavService? get _server => caldav?.isConnected == true ? caldav : null;

  @override
  Future<List<DayEvent>> events(DateTime from, DateTime to) async => [
        ...?await _server?.events(from, to),
        ...?await device?.events(from, to),
        ...?await ics?.events(from, to),
      ];

  @override
  Future<List<DayEvent>?> eventsIn(String target, DateTime from, DateTime to) async => target.startsWith('phone:')
      ? await device?.readCalendarNow(target.substring('phone:'.length), from, to)
      : await _server?.readCalendarNow(target, from, to);

  @override
  Future<List<CalendarInfo>> writable() async => [...?await _server?.writableCalendars(), ...?await device?.writableCalendars()];

  @override
  List<CalendarPlace> get places => [if (device?.isSupported == true) CalendarPlace.phone, if (_server != null) CalendarPlace.server];

  @override
  Future<CalendarInfo> makeCalendar(CalendarPlace place, String name) async => switch (place) {
        CalendarPlace.phone => device!.createCalendar(name, color: '#2E7D32'),
        CalendarPlace.server => _server!.createEventCalendar(name, color: '#2E7D32'),
      };

  @override
  Future<String> create(String target, NewEvent event) =>
      target.startsWith('phone:') ? device!.createEvent(target.substring('phone:'.length), event) : caldav!.createEvent(target, event);

  @override
  Future<void> delete(String target, String id) async {
    if (target.startsWith('phone:')) {
      await device?.deleteEvent(id);
    } else {
      await _server?.deleteEvent(target, id);
    }
  }
}
