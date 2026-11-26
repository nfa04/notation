import '../data/event_repository.dart';
import '../reminders/reminder.dart';
import 'caldav_remote.dart' show DayEvent;
import 'ics.dart';
import 'ics_write.dart';

String _two(int n) => n.toString().padLeft(2, '0');
String _dateOf(DateTime d) => '${d.year.toString().padLeft(4, '0')}${_two(d.month)}${_two(d.day)}';
String _wallOf(DateTime d) => '${_dateOf(d)}T${_two(d.hour)}${_two(d.minute)}${_two(d.second)}';

/// An event of the app's own calendars as an iCalendar text with floating times (wall clock, in the zone of the person looking), so
/// that the one reader of repeat rules, [expandIcs], can repeat it like any other event.
String _asIcs(LocalEvent e) {
  final lines = <String>[
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'BEGIN:VEVENT',
    'UID:${e.id}',
    if (e.allDay) ...['DTSTART;VALUE=DATE:${_dateOf(e.start)}', 'DTEND;VALUE=DATE:${_dateOf(e.end)}'] else ...['DTSTART:${_wallOf(e.start)}', 'DTEND:${_wallOf(e.end)}'],
    'SUMMARY:${escapeIcsText(e.title)}',
    if (e.notes != null && e.notes!.isNotEmpty) 'DESCRIPTION:${escapeIcsText(e.notes!)}',
    if (e.location != null && e.location!.isNotEmpty) 'LOCATION:${escapeIcsText(e.location!)}',
    if (e.url != null && e.url!.isNotEmpty) 'URL:${e.url}',
    if (e.repeats) 'RRULE:${e.rrule}',
    for (final d in e.exdates) e.allDay ? 'EXDATE;VALUE=DATE:${_dateOf(d)}' : 'EXDATE:${_wallOf(d)}',
    for (final a in e.attendees) 'ATTENDEE:mailto:$a',
    for (final m in e.alarms) ...['BEGIN:VALARM', 'ACTION:DISPLAY', 'TRIGGER:${alarmTrigger(m)}', 'END:VALARM'],
    'END:VEVENT',
    'END:VCALENDAR',
  ];
  return '${lines.map(foldIcsLine).join('\r\n')}\r\n';
}

/// The days of [e] that touch the time from [from] to [to], repeats expanded, as the calendar view shows them. Notes, place and
/// link are '' (not null) when there are none: for an event of the app's own calendar they are known, and the dialog asks for them.
List<DayEvent> expandLocalEvent(LocalEvent e, DateTime from, DateTime to, {required String calendarName, required String key, String? color}) {
  final shown = expandIcs(parseIcs(_asIcs(e)), from, to, calendarName: calendarName, key: key, color: color);
  return [for (final d in shown) d.copyWith(notes: d.notes ?? '', location: d.location ?? '', url: d.url ?? '')];
}

/// The moments in [from, to) at which an alarm of an event of the app's own calendars goes off.
Future<List<EventAlarm>> localEventAlarms(EventRepository repo, DateTime from, DateTime to) async {
  final calendars = {for (final c in await repo.calendars()) c.id: c};
  final out = <EventAlarm>[];
  for (final e in await repo.eventsIn(from, to.add(const Duration(days: 7)))) {
    if (e.alarms.isEmpty || calendars[e.calendarId] == null) continue;
    for (final o in expandLocalEvent(e, from, to.add(const Duration(days: 7)), calendarName: '', key: '')) {
      // (an all-day event is announced from the start of its day)
      for (final m in e.alarms) {
        final at = o.start.subtract(Duration(minutes: m));
        if (!at.isBefore(from) && at.isBefore(to)) out.add(EventAlarm(key: '${e.id}|${o.start.millisecondsSinceEpoch}|$m', title: e.title, at: at));
      }
    }
  }
  return out;
}
