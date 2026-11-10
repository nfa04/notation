import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'caldav_remote.dart' show DayEvent;

/// Reading `.ics` files (iCalendar, RFC 5545): the events of a calendar that was
/// exported from Google, Apple, Outlook, Nextcloud, a university's timetable...
/// including repeating events (RRULE with its exceptions) and time zones.
///
/// Times are kept as "wall clock" values (a [DateTime] in UTC used as a plain
/// date and time) together with the zone they were written in, so that a
/// weekly 10:00 meeting stays at 10:00 across a change to summer time.

/// One event as written in the file.
class IcsEvent {
  final String uid;
  final String summary;
  final String? location;

  /// Wall clock time, and the zone it is in: null is "floating" (the viewer's
  /// own), 'UTC' is UTC, anything else an IANA name such as 'Europe/Zurich'.
  final DateTime start;
  final DateTime end; // exclusive
  final String? zone;
  final bool allDay;
  final Map<String, String>? rrule;
  final Set<int> exdates; // wall clock milliseconds; for all-day events the midnight of the day

  /// For a changed single occurrence of a repeating event: the wall clock start it replaces.
  final DateTime? recurrenceId;
  final bool cancelled;

  const IcsEvent({
    required this.uid,
    required this.summary,
    this.location,
    required this.start,
    required this.end,
    required this.zone,
    required this.allDay,
    this.rrule,
    this.exdates = const {},
    this.recurrenceId,
    this.cancelled = false,
  });
}

/// What a file holds.
class IcsCalendar {
  final String? name;

  /// '#RRGGBB' when the file says one.
  final String? color;
  final List<IcsEvent> events;

  const IcsCalendar({this.name, this.color, required this.events});
}

class _Prop {
  final String name;
  final Map<String, String> params;
  final String value;
  const _Prop(this.name, this.params, this.value);
}

/// Windows zone names (Outlook) -> IANA, for the common ones.
const _windowsZones = {
  'W. Europe Standard Time': 'Europe/Berlin',
  'Central Europe Standard Time': 'Europe/Budapest',
  'Romance Standard Time': 'Europe/Paris',
  'Central European Standard Time': 'Europe/Warsaw',
  'GMT Standard Time': 'Europe/London',
  'E. Europe Standard Time': 'Europe/Chisinau',
  'FLE Standard Time': 'Europe/Kiev',
  'GTB Standard Time': 'Europe/Bucharest',
  'Russian Standard Time': 'Europe/Moscow',
  'Turkey Standard Time': 'Europe/Istanbul',
  'Eastern Standard Time': 'America/New_York',
  'Central Standard Time': 'America/Chicago',
  'Mountain Standard Time': 'America/Denver',
  'Pacific Standard Time': 'America/Los_Angeles',
  'Alaskan Standard Time': 'America/Anchorage',
  'Hawaiian Standard Time': 'Pacific/Honolulu',
  'Canada Central Standard Time': 'America/Regina',
  'Atlantic Standard Time': 'America/Halifax',
  'E. South America Standard Time': 'America/Sao_Paulo',
  'Argentina Standard Time': 'America/Argentina/Buenos_Aires',
  'India Standard Time': 'Asia/Kolkata',
  'China Standard Time': 'Asia/Shanghai',
  'Tokyo Standard Time': 'Asia/Tokyo',
  'Korea Standard Time': 'Asia/Seoul',
  'Singapore Standard Time': 'Asia/Singapore',
  'AUS Eastern Standard Time': 'Australia/Sydney',
  'New Zealand Standard Time': 'Pacific/Auckland',
  'South Africa Standard Time': 'Africa/Johannesburg',
  'Egypt Standard Time': 'Africa/Cairo',
  'Arab Standard Time': 'Asia/Riyadh',
  'UTC': 'UTC',
};

bool _zonesReady = false;

tz.Location? _location(String? name) {
  if (name == null) return null;
  if (!_zonesReady) {
    tzdata.initializeTimeZones();
    _zonesReady = true;
  }
  try {
    return tz.getLocation(_windowsZones[name] ?? name.replaceAll(RegExp(r'^/[^/]*/'), ''));
  } catch (_) {
    return null;
  }
}

// ---- reading the file --------------------------------------------------------

String _unescape(String s) =>
    s.replaceAllMapped(RegExp(r'\\([nN,;\\])'), (m) => m[1] == 'n' || m[1] == 'N' ? '\n' : m[1]!);

_Prop? _parseLine(String line) {
  // NAME;PARAM=value;PARAM="quoted:value":value  -- the first colon outside quotes ends the name part
  var quoted = false;
  var colon = -1;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') quoted = !quoted;
    if (c == ':' && !quoted) {
      colon = i;
      break;
    }
  }
  if (colon <= 0) return null;
  final head = line.substring(0, colon);
  final parts = <String>[];
  var start = 0;
  quoted = false;
  for (var i = 0; i < head.length; i++) {
    if (head[i] == '"') quoted = !quoted;
    if (head[i] == ';' && !quoted) {
      parts.add(head.substring(start, i));
      start = i + 1;
    }
  }
  parts.add(head.substring(start));
  final params = <String, String>{};
  for (final p in parts.skip(1)) {
    final eq = p.indexOf('=');
    if (eq > 0) params[p.substring(0, eq).toUpperCase()] = p.substring(eq + 1).replaceAll('"', '');
  }
  return _Prop(parts.first.toUpperCase(), params, line.substring(colon + 1));
}

/// A date or date-time value: wall clock time, whether it was a date only, and
/// the zone ('UTC' for a trailing Z, the TZID, or null).
({DateTime time, bool dateOnly, String? zone})? _parseTime(String value, Map<String, String> params) {
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$').firstMatch(value.trim());
  if (m == null) return null;
  final dateOnly = m[4] == null || params['VALUE'] == 'DATE';
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  final h = dateOnly ? 0 : int.parse(m[4]!), mi = dateOnly ? 0 : int.parse(m[5]!), sec = dateOnly ? 0 : int.parse(m[6] ?? '0');
  // (a date that does not exist - month 13, February 30th, hour 25 - is no date; DateTime would roll it over into the next year or month)
  // (a leap second, 60, is the last second of its minute)
  if (mo < 1 || mo > 12 || d < 1 || d > DateTime.utc(y, mo + 1, 0).day || h > 23 || mi > 59 || sec > 60) return null;
  final time = DateTime.utc(y, mo, d, h, mi, sec > 59 ? 59 : sec);
  final zone = dateOnly ? null : (m[7] != null ? 'UTC' : params['TZID']);
  return (time: time, dateOnly: dateOnly, zone: zone);
}

Duration? _parseDuration(String v) {
  final m = RegExp(r'^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$').firstMatch(v.trim());
  if (m == null) return null;
  int n(int i) => int.tryParse(m[i] ?? '') ?? 0;
  final d = Duration(days: n(2) * 7 + n(3), hours: n(4), minutes: n(5), seconds: n(6));
  return m[1] == '-' ? -d : d;
}

Map<String, String>? _parseRule(String v) {
  final rule = <String, String>{};
  for (final part in v.split(';')) {
    final eq = part.indexOf('=');
    if (eq > 0) rule[part.substring(0, eq).toUpperCase()] = part.substring(eq + 1);
  }
  return rule.containsKey('FREQ') ? rule : null;
}

String? _color(String? v) {
  final m = RegExp(r'^#?([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$').firstMatch(v?.trim() ?? '');
  return m == null ? null : '#${m[1]!.toUpperCase()}';
}

/// The calendar in [text]. Anything unreadable is skipped, not fatal.
IcsCalendar parseIcs(String text) {
  final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll(RegExp(r'\n[ \t]'), '').split('\n');
  String? name, color;
  final events = <IcsEvent>[];
  List<_Prop>? current;
  var depth = 0; // inside an event: nested alarms are skipped

  for (final raw in lines) {
    final line = raw.trimRight();
    if (line.isEmpty) continue;
    final upper = line.toUpperCase();
    if (upper == 'BEGIN:VEVENT') {
      current = [];
      depth = 0;
      continue;
    }
    if (current != null) {
      if (upper.startsWith('BEGIN:')) {
        depth++;
        continue;
      }
      if (upper == 'END:VEVENT' && depth == 0) {
        final event = _event(current);
        if (event != null) events.add(event);
        current = null;
        continue;
      }
      if (upper.startsWith('END:')) {
        depth--;
        continue;
      }
      if (depth == 0) {
        final p = _parseLine(line);
        if (p != null) current.add(p);
      }
      continue;
    }
    final p = _parseLine(line);
    if (p == null) continue;
    if (p.name == 'X-WR-CALNAME') name ??= _unescape(p.value).trim();
    if (p.name == 'X-APPLE-CALENDAR-COLOR' || p.name == 'X-WR-CALCOLOR') color ??= _color(p.value);
  }
  return IcsCalendar(name: name == null || name.isEmpty ? null : name, color: color, events: events);
}

IcsEvent? _event(List<_Prop> props) {
  _Prop? one(String name) => props.where((p) => p.name == name).firstOrNull;
  final dtstart = one('DTSTART');
  if (dtstart == null) return null;
  final start = _parseTime(dtstart.value, dtstart.params);
  if (start == null) return null;

  DateTime end;
  final dtend = one('DTEND');
  final duration = one('DURATION');
  final parsedEnd = dtend == null ? null : _parseTime(dtend.value, dtend.params);
  if (parsedEnd != null) {
    // (an end in another zone than the start, a flight: the end is kept as the wall clock of the start's zone)
    end = start.dateOnly || parsedEnd.dateOnly ? parsedEnd.time : _wallIn(parsedEnd.time, parsedEnd.zone, start.zone);
  } else if (duration != null && _parseDuration(duration.value) != null) {
    end = start.time.add(_parseDuration(duration.value)!);
  } else {
    end = start.dateOnly ? start.time.add(const Duration(days: 1)) : start.time;
  }
  if (end.isBefore(start.time)) end = start.time;

  final exdates = <int>{};
  for (final p in props.where((p) => p.name == 'EXDATE')) {
    for (final v in p.value.split(',')) {
      final t = _parseTime(v, p.params);
      if (t != null) exdates.add((t.dateOnly ? t.time : _wallIn(t.time, t.zone, start.zone)).millisecondsSinceEpoch);
    }
  }
  final recurrence = one('RECURRENCE-ID');
  final recurrenceTime = recurrence == null ? null : _parseTime(recurrence.value, recurrence.params);
  final rule = one('RRULE');
  return IcsEvent(
    uid: one('UID')?.value ?? '',
    summary: _unescape(one('SUMMARY')?.value ?? '').trim(),
    location: one('LOCATION') == null ? null : _unescape(one('LOCATION')!.value).trim(),
    start: start.time,
    end: end,
    zone: start.zone,
    allDay: start.dateOnly,
    rrule: rule == null ? null : _parseRule(rule.value),
    exdates: exdates,
    recurrenceId: recurrenceTime == null ? null : (recurrenceTime.dateOnly ? recurrenceTime.time : _wallIn(recurrenceTime.time, recurrenceTime.zone, start.zone)),
    cancelled: one('STATUS')?.value.toUpperCase() == 'CANCELLED',
  );
}

// ---- time zones --------------------------------------------------------------

/// The moment a wall clock time in [zone] is, as milliseconds since the epoch.
int _instant(DateTime wall, String? zone) {
  if (zone == 'UTC') return wall.millisecondsSinceEpoch;
  final loc = _location(zone);
  if (loc == null) {
    // floating, or a zone we do not know: the viewer's own clock
    return DateTime(wall.year, wall.month, wall.day, wall.hour, wall.minute, wall.second).millisecondsSinceEpoch;
  }
  return tz.TZDateTime(loc, wall.year, wall.month, wall.day, wall.hour, wall.minute, wall.second).millisecondsSinceEpoch;
}

DateTime _local(DateTime wall, String? zone) => DateTime.fromMillisecondsSinceEpoch(_instant(wall, zone));

/// The wall clock time in [to] of the moment that [wall] is in [from]. A time with no zone of its own ([from] null: a date, or a
/// floating time) is taken to be in [to] already.
DateTime _wallIn(DateTime wall, String? from, String? to) {
  if (from == null || from == to) return wall;
  final ms = _instant(wall, from);
  if (to == 'UTC') return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  final loc = _location(to);
  final t = loc == null ? DateTime.fromMillisecondsSinceEpoch(ms) : tz.TZDateTime.fromMillisecondsSinceEpoch(loc, ms);
  return DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second);
}

// ---- repeating events ----------------------------------------------------------

const _weekdays = {'MO': 1, 'TU': 2, 'WE': 3, 'TH': 4, 'FR': 5, 'SA': 6, 'SU': 7};

DateTime _day(int y, int m, int d) => DateTime.utc(y, m, d);

int _daysIn(int y, int m) => DateTime.utc(y, m + 1, 0).day;

/// The wall clock starts of a repeating event: lazily, in order, from [first]
/// on, never past [limit] (a day past the end of what is wanted).
Iterable<DateTime> _occurrences(DateTime first, Map<String, String> rule, DateTime limit) sync* {
  final freq = rule['FREQ']!.toUpperCase();
  final interval = (int.tryParse(rule['INTERVAL'] ?? '') ?? 1).clamp(1, 1000);
  final count = int.tryParse(rule['COUNT'] ?? '');
  final wkst = _weekdays[rule['WKST']?.toUpperCase()] ?? 1;
  List<int> ints(String? v) => [for (final s in (v ?? '').split(',')) ?int.tryParse(s.trim())];
  final byMonth = ints(rule['BYMONTH']);
  final byMonthDay = ints(rule['BYMONTHDAY']);
  final bySetPos = ints(rule['BYSETPOS']);
  // BYDAY entries: an optional number ("2" second, "-1" last) and a weekday
  final byDay = <({int ordinal, int weekday})>[];
  for (final s in (rule['BYDAY'] ?? '').split(',')) {
    final m = RegExp(r'^([+-]?\d+)?(MO|TU|WE|TH|FR|SA|SU)$').firstMatch(s.trim().toUpperCase());
    if (m != null) byDay.add((ordinal: int.tryParse(m[1] ?? '') ?? 0, weekday: _weekdays[m[2]]!));
  }

  var produced = 0;
  DateTime at(DateTime date) => DateTime.utc(date.year, date.month, date.day, first.hour, first.minute, first.second);
  final firstDay = _day(first.year, first.month, first.day);

  /// Days of one month that the rule picks (before BYSETPOS).
  List<DateTime> monthDays(int y, int m, {bool useStartDay = true}) {
    final days = <int>{};
    final length = _daysIn(y, m);
    if (byMonthDay.isNotEmpty) {
      for (final d in byMonthDay) {
        final day = d < 0 ? length + d + 1 : d;
        if (day >= 1 && day <= length) days.add(day);
      }
      if (byDay.isNotEmpty) {
        days.removeWhere((d) => !byDay.any((b) => b.weekday == _day(y, m, d).weekday));
      }
    } else if (byDay.isNotEmpty) {
      for (final b in byDay) {
        final matching = [for (var d = 1; d <= length; d++) if (_day(y, m, d).weekday == b.weekday) d];
        if (b.ordinal == 0) {
          days.addAll(matching);
        } else {
          final i = b.ordinal > 0 ? b.ordinal - 1 : matching.length + b.ordinal;
          if (i >= 0 && i < matching.length) days.add(matching[i]);
        }
      }
    } else if (useStartDay && first.day <= length) {
      days.add(first.day);
    }
    return [for (final d in (days.toList()..sort())) _day(y, m, d)];
  }

  List<DateTime> pick(List<DateTime> days) {
    if (bySetPos.isEmpty) return days;
    return [
      for (final p in bySetPos)
        if (p > 0 ? p <= days.length : -p <= days.length) days[p > 0 ? p - 1 : days.length + p],
    ];
  }

  // a period gives its days; those before the start are not occurrences
  Iterable<DateTime> emit(List<DateTime> days) sync* {
    for (final d in days) {
      if (d.isBefore(firstDay)) continue;
      if (!at(d).isBefore(limit.add(const Duration(days: 1)))) return;
      yield at(d);
    }
  }

  var guard = 0;
  switch (freq) {
    case 'DAILY':
      for (var k = 0; guard++ < 100000; k++) {
        final d = firstDay.add(Duration(days: k * interval));
        if (d.isAfter(limit)) return;
        if (byMonth.isNotEmpty && !byMonth.contains(d.month)) continue;
        if (byDay.isNotEmpty && !byDay.any((b) => b.weekday == d.weekday)) continue;
        if (byMonthDay.isNotEmpty &&
            !byMonthDay.any((x) => (x < 0 ? _daysIn(d.year, d.month) + x + 1 : x) == d.day)) {
          continue;
        }
        if (count != null && ++produced > count) return;
        yield at(d);
      }
    case 'WEEKLY':
      final weekStart = firstDay.subtract(Duration(days: (firstDay.weekday - wkst + 7) % 7));
      final wanted = byDay.isEmpty ? [firstDay.weekday] : [for (final b in byDay) b.weekday];
      for (var k = 0; guard++ < 20000; k++) {
        final ws = weekStart.add(Duration(days: 7 * k * interval));
        if (ws.isAfter(limit)) return;
        final days = [for (final w in wanted) ws.add(Duration(days: (w - wkst + 7) % 7))]..sort();
        for (final d in pick(days)) {
          if (d.isBefore(firstDay)) continue;
          if (byMonth.isNotEmpty && !byMonth.contains(d.month)) continue;
          if (d.isAfter(limit)) return;
          if (count != null && ++produced > count) return;
          yield at(d);
        }
      }
    case 'MONTHLY':
      for (var k = 0; guard++ < 5000; k++) {
        final index = first.year * 12 + first.month - 1 + k * interval;
        final y = index ~/ 12, m = index % 12 + 1;
        if (_day(y, m, 1).isAfter(limit)) return;
        if (byMonth.isNotEmpty && !byMonth.contains(m)) continue;
        for (final d in emit(pick(monthDays(y, m)))) {
          if (count != null && ++produced > count) return;
          yield d;
        }
      }
    case 'YEARLY':
      for (var k = 0; guard++ < 1000; k++) {
        final y = first.year + k * interval;
        if (_day(y, 1, 1).isAfter(limit)) return;
        final months = byMonth.isNotEmpty ? (byMonth.toList()..sort()) : [first.month];
        final days = <DateTime>[];
        if (byMonth.isEmpty && byDay.isNotEmpty && byMonthDay.isEmpty) {
          // "the 20th Monday of the year" and the like: ordinals count in the year
          for (final b in byDay) {
            final matching = [
              for (var d = _day(y, 1, 1); d.year == y; d = d.add(const Duration(days: 1))) if (d.weekday == b.weekday) d
            ];
            if (b.ordinal == 0) {
              days.addAll(matching);
            } else {
              final i = b.ordinal > 0 ? b.ordinal - 1 : matching.length + b.ordinal;
              if (i >= 0 && i < matching.length) days.add(matching[i]);
            }
          }
        } else {
          for (final m in months) {
            days.addAll(monthDays(y, m));
          }
        }
        days.sort();
        for (final d in emit(pick(days))) {
          if (count != null && ++produced > count) return;
          yield d;
        }
      }
    default:
      // an unknown frequency: only the first one
      yield at(firstDay);
  }
}

/// The events of [calendar] that touch the time from [from] to [to] (local
/// times), repeats expanded, as [DayEvent]s of the calendar [key].
List<DayEvent> expandIcs(IcsCalendar calendar, DateTime from, DateTime to,
    {required String calendarName, required String key, String? color}) {
  final masters = <IcsEvent>[];
  final changed = <String, List<IcsEvent>>{}; // by uid
  for (final e in calendar.events) {
    if (e.recurrenceId != null) {
      changed.putIfAbsent(e.uid, () => []).add(e);
    } else {
      masters.add(e);
    }
  }

  final out = <DayEvent>[];

  void add(IcsEvent e, DateTime start, DateTime end, {required bool repeats}) {
    final DateTime shownStart, shownEnd;
    if (e.allDay) {
      shownStart = DateTime(start.year, start.month, start.day);
      final last = DateTime(end.year, end.month, end.day - 1);
      shownEnd = last.isAfter(shownStart) ? last : shownStart;
      if (shownStart.isAfter(to) || shownEnd.add(const Duration(days: 1)).isBefore(from)) return;
      out.add(DayEvent(
        title: e.summary,
        start: shownStart,
        end: shownEnd.isAfter(shownStart) ? shownEnd : null,
        allDay: true,
        calendarName: calendarName,
        color: color,
        repeats: repeats,
        calendarKey: key,
        uid: e.uid,
      ));
      return;
    }
    shownStart = _local(start, e.zone);
    shownEnd = _local(end, e.zone);
    if (!shownStart.isBefore(to) || shownEnd.isBefore(from) || (shownEnd == shownStart && shownStart.isBefore(from))) return;
    out.add(DayEvent(
      title: e.summary,
      start: shownStart,
      end: shownEnd.isAfter(shownStart) ? shownEnd : null,
      allDay: false,
      calendarName: calendarName,
      color: color,
      repeats: repeats,
      calendarKey: key,
      uid: e.uid,
    ));
  }

  final seenMasters = <String>{};
  for (final e in masters) {
    if (e.cancelled) {
      seenMasters.add(e.uid); // (a cancelled series is gone, with the changes made to its occurrences)
      continue;
    }
    final length = e.end.difference(e.start);
    final overrides = {
      for (final o in changed[e.uid] ?? const <IcsEvent>[]) o.recurrenceId!.millisecondsSinceEpoch: o,
    };
    seenMasters.add(e.uid);
    if (e.rrule == null) {
      add(e, e.start, e.end, repeats: false);
      continue;
    }
    // wall clock limit: a day past the wanted time covers every zone
    final limit = DateTime.utc(to.year, to.month, to.day).add(const Duration(days: 2));
    final until = e.rrule!['UNTIL'];
    final untilTime = until == null ? null : _parseTime(until, const {});
    final reached = <int>{};
    for (final start in _occurrences(e.start, e.rrule!, limit)) {
      if (untilTime != null) {
        final past = untilTime.dateOnly
            ? start.isAfter(untilTime.time.add(const Duration(days: 1)).subtract(const Duration(milliseconds: 1)))
            : _instant(start, e.zone) > _instant(untilTime.time, untilTime.zone ?? e.zone);
        if (past) break;
      }
      final stamp = start.millisecondsSinceEpoch;
      if (e.exdates.contains(stamp)) continue;
      final o = overrides[stamp];
      if (o != null) {
        reached.add(stamp);
        if (!o.cancelled) add(o, o.start, o.end, repeats: true);
        continue;
      }
      add(e, start, start.add(length), repeats: true);
    }
    // a changed occurrence whose original time was not looked at (it was past the end of what is wanted, and it was moved into it)
    for (final o in overrides.entries) {
      if (reached.contains(o.key) || e.exdates.contains(o.key) || o.value.cancelled) continue;
      add(o.value, o.value.start, o.value.end, repeats: true);
    }
  }
  // changed occurrences whose repeating event is not in the file stand on their own
  for (final entry in changed.entries) {
    if (seenMasters.contains(entry.key)) continue;
    for (final o in entry.value) {
      if (!o.cancelled) add(o, o.start, o.end, repeats: false);
    }
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}
