import 'caldav_remote.dart';
import 'caldav_service.dart';
import 'device_calendar_service.dart';
import 'ics_service.dart';

/// The calendars of the person as one: the events they hold, and where a new event can be written (the same sources the calendar
/// screen shows). The assistant and the extensions reach the calendar through it.
class CalendarAccess {
  /// The events of the days [from] to [to] (inclusive), from every calendar that is shown.
  final Future<List<DayEvent>> Function(DateTime from, DateTime to) events;

  /// The calendars an event can be added to.
  final Future<List<CalendarInfo>> Function() writable;

  /// Writes [event] to the calendar [target].
  final Future<void> Function(CalendarInfo target, NewEvent event) create;

  const CalendarAccess({required this.events, required this.writable, required this.create});

  factory CalendarAccess.of({CalDavService? caldav, DeviceCalendarService? device, IcsCalendarService? ics}) {
    CalDavService? server() => caldav?.isConnected == true ? caldav : null;
    return CalendarAccess(
      events: (from, to) async {
        final all = [
          ...?await server()?.events(from, to),
          ...?await device?.events(from, to),
          ...?await ics?.events(from, to),
        ];
        return all..sort((a, b) => a.start.compareTo(b.start));
      },
      writable: () async => [...?await server()?.writableCalendars(), ...?await device?.writableCalendars()],
      create: (target, event) async {
        if (target.key.startsWith('phone:')) {
          await device!.createEvent(target.key.substring('phone:'.length), event);
        } else {
          await server()!.createEvent(target.key, event);
        }
      },
    );
  }
}
